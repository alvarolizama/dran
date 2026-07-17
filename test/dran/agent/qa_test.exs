defmodule Dran.Agent.QATest do
  # Tests for Dran.Agent.QA — the "ask" agent.
  #
  # Two layers:
  #   1. Unit test of create_query_page limit (inference disabled, no LLM).
  #   2. Full E2E test: the engine runs the real ReAct loop with the LLM
  #      mocked via Req.Test stubs (pattern copied from
  #      test/dran/agent/ingest/utils_test.exs). The stub returns a
  #      scripted sequence of tool_calls: search → get_page →
  #      create_query_page → done.
  use Dran.DataCase, async: false

  alias Dran.Agent.{Engine, QA, Session}
  alias Dran.{Brain, Repo}

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp build_session(attrs \\ []) do
    struct(
      %Session{
        id: Ecto.UUID.generate(),
        context_id: Ecto.UUID.generate(),
        agent_type: "ask",
        input: "¿Qué es Elixir?",
        status: "running"
      },
      attrs
    )
  end

  defp build_state(attrs) do
    struct(
      %QA.State{
        session: build_session(),
        pages_created: 0,
        opts: []
      },
      attrs
    )
  end

  defp inference_env do
    original = Application.get_env(:dran, :inference)

    Application.put_env(:dran, :inference,
      base_url: "http://localhost:8000/v1",
      api_key: "test-key",
      chat_model: "test-chat-model",
      embedding_model: "test-embed-model",
      rerank_model: "test-rerank-model",
      markitdown_model: "test-md-model",
      timeout: 5_000,
      req_plug: {Req.Test, Dran.Inference.Client},
      schedule_async: false
    )

    original
  end

  defp no_inference_env do
    original = Application.get_env(:dran, :inference)

    Application.put_env(:dran, :inference,
      base_url: nil,
      api_key: nil,
      timeout: 100,
      schedule_async: false
    )

    original
  end

  defp restore_env(nil), do: Application.delete_env(:dran, :inference)
  defp restore_env(env), do: Application.put_env(:dran, :inference, env)

  defp ensure_queue_started(capability) do
    case Registry.start_link(keys: :unique, name: Dran.Inference.QueueRegistry) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    case Dran.Inference.Queue.start_link(capability: capability) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  # A chat-completion response with a single tool_call.
  defp tool_call_response(tool, args, id) do
    %{
      "choices" => [
        %{
          "message" => %{
            "role" => "assistant",
            "content" => "Razonando sobre #{tool}",
            "tool_calls" => [
              %{
                "id" => id,
                "type" => "function",
                "function" => %{
                  "name" => tool,
                  "arguments" => Jason.encode!(args)
                }
              }
            ]
          }
        }
      ],
      "model" => "test-chat-model",
      "usage" => %{"total_tokens" => 10}
    }
  end

  defp seed_context do
    Brain.get_context_by_slug("personal") ||
      elem(Brain.create_context(%{name: "Personal", slug: "personal"}), 1)
  end

  # ── Unit: create_query_page limit (inference disabled) ─────────────────────

  describe "create_query_page one-per-session limit" do
    setup do
      original = no_inference_env()
      context = seed_context()

      on_exit(fn -> restore_env(original) end)

      {:ok, context: context}
    end

    test "rejects a second create_query_page with 'already created'",
         %{context: ctx} do
      state =
        build_state(
          session: build_session(context_id: ctx.id),
          query_page_created: true
        )

      {{:error, reason}, new_state} =
        QA.execute_tool(
          "create_query_page",
          %{"title" => "segunda", "answer" => "no debe crearse"},
          state
        )

      assert reason == "already created"
      # State unchanged: still flagged as created.
      assert new_state.query_page_created == true
      assert new_state.pages_created == 0
    end

    test "creates the first query page and sets the flag", %{context: ctx} do
      state = build_state(session: build_session(context_id: ctx.id))

      {{:ok, result}, new_state} =
        QA.execute_tool(
          "create_query_page",
          %{
            "title" => "Pregunta sobre Elixir",
            "slug" => "pregunta-elixir",
            "answer" => "Elixir es un lenguaje funcional [elixir-lang].",
            "kind" => "factual",
            "difficulty" => "simple",
            "answer_status" => "answered"
          },
          state
        )

      assert result.slug == "pregunta-elixir"
      assert new_state.query_page_created == true
      assert new_state.pages_created == 1

      page = Brain.get_page_by_slug("pregunta-elixir", ctx.id)
      assert page.page_type == "query"
      assert page.body =~ "Elixir es un lenguaje funcional"
      assert page.created_by == "qa-agent"
      assert page.owner == "qa-agent"
      assert page.meta["answer_status"] == "answered"
      assert page.meta["answered_by"] == "qa-agent"
      assert page.meta["kind"] == "factual"
      assert page.meta["difficulty"] == "simple"
      assert page.meta["agent_session_id"] == state.session.id
    end
  end

  # ── E2E: full agent flow with stubbed LLM ──────────────────────────────────

  describe "full agent run with stubbed LLM" do
    setup do
      original = inference_env()

      ensure_queue_started(:chat)
      ensure_queue_started(:embed)

      context = seed_context()

      # Stub MUST be set before seeding the source page, because
      # Brain.create_page triggers Embeddings.schedule (synchronous with
      # schedule_async: false) which calls /v1/embeddings.
      setup_routing_stub(context.id)

      # Seed a source page the agent will find via search and read via get_page.
      {:ok, source_page} =
        Brain.create_page(%{
          context_id: context.id,
          title: "Elixir Language",
          slug: "elixir-lang",
          body: "Elixir es un lenguaje de programación funcional, concurrente, que corre sobre la VM de Erlang.",
          page_type: "concept",
          tags: ["programming", "elixir"]
        })

      # Reset the scripted chat counter for each test.
      case :persistent_term.get({__MODULE__, :chat_seq}, nil) do
        nil -> :ok
        ref -> :counters.put(ref, 1, 0)
      end

      on_exit(fn -> restore_env(original) end)

      {:ok, context: context, source_page: source_page}
    end

    test "search → get_page → create_query_page → done creates an answered query page",
         %{context: ctx} do
      {:ok, session} = Engine.run(QA, "¿Qué es Elixir?", ctx.id)

      # Wait for the async loop to finish.
      assert eventually(fn ->
               s = Repo.get(Session, session.id)
               s.status in ["done", "failed"]
             end)

      session = Repo.get(Session, session.id)
      assert session.status == "done", "session failed: #{session.summary}"

      # The query page must exist with answer_status "answered" and the
      # synthesized body citing the source slug.
      query_page = Brain.get_page_by_slug("que-es-elixir", ctx.id)

      assert query_page != nil, "query page was not created"
      assert query_page.page_type == "query"
      assert query_page.meta["answer_status"] == "answered"
      assert query_page.meta["answered_by"] == "qa-agent"
      assert query_page.meta["agent_session_id"] == session.id
      assert query_page.body =~ "Elixir"
      assert query_page.body =~ "[elixir-lang]"
      assert query_page.created_by == "qa-agent"
    end
  end

  # ── Internal: scripted chat responses ─────────────────────────────────────

  # The scripted sequence of tool_calls the stub returns, in order.
  @chat_sequence [
    {"search", %{"query" => "Elixir lenguaje"}},
    {"search", %{"query" => "Elixir programación funcional"}},
    {"get_page", %{"slug" => "elixir-lang"}},
    {"create_query_page",
     %{
       "title" => "¿Qué es Elixir?",
       "slug" => "que-es-elixir",
       "answer" =>
         "Elixir es un lenguaje de programación funcional y concurrente que corre sobre la VM de Erlang [elixir-lang].",
       "kind" => "factual",
       "difficulty" => "simple",
       "answer_status" => "answered",
       "tags" => ["programming", "elixir"]
     }},
    {"done", %{"summary" => "Respuesta creadada a partir de elixir-lang."}}
  ]

  defp setup_routing_stub(_context_id) do
    Req.Test.stub(Dran.Inference.Client, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      case conn.request_path do
        "/v1/embeddings" ->
          Req.Test.json(conn, %{
            "object" => "list",
            "data" => [
              %{"object" => "embedding", "index" => 0, "embedding" => [0.1 | List.duplicate(0.0, 1023)]}
            ]
          })

        "/v1/chat/completions" ->
          decoded = Jason.decode!(body)

          # PageAugmenter calls with a non-chat model for summaries —
          # answer generically so it doesn't interfere.
          if decoded["model"] != "test-chat-model" do
            Req.Test.json(conn, %{
              "choices" => [%{"message" => %{"role" => "assistant", "content" => "{}"}}]
            })
          else
            respond_chat(conn)
          end

        _ ->
          Plug.Conn.resp(conn, 404, "{}")
      end
    end)
  end

  defp respond_chat(conn) do
    count = chat_counter_tick()

    {tool, args} = Enum.at(@chat_sequence, count, List.last(@chat_sequence))
    id = "call_#{count + 1}"

    Req.Test.json(conn, tool_call_response(tool, args, id))
  end

  # The engine runs each turn in its own Task, so Process.get/put can't carry
  # the sequence position across LLM calls. :counters is process-independent.
  defp chat_counter_tick do
    key = {__MODULE__, :chat_seq}

    case :persistent_term.get(key, nil) do
      nil ->
        ref = :counters.new(1, [])
        :persistent_term.put(key, ref)
        :counters.add(ref, 1, 1)
        0

      ref ->
        current = :counters.get(ref, 1)
        :counters.add(ref, 1, 1)
        current
    end
  end

  defp eventually(fun, attempts \\ 60)

  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(100)
      eventually(fun, attempts - 1)
    end
  end
end
