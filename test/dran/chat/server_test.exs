defmodule Dran.Chat.ServerTest do
  use Dran.DataCase, async: false

  # Shared sandbox mode so the GenServer (running in a different process)
  # and the agent task (spawned by Task.Supervisor) can see the test's
  # DB transactions.
  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Dran.Repo, {:shared, self()})
    :ok
  end

  alias Dran.Chat.{Server, Session}
  alias Dran.{Brain, Repo}
  alias Dran.Brain.Page

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp ensure_context! do
    Brain.get_context_by_slug("personal") ||
      elem(Brain.create_context(%{name: "Personal", slug: "personal"}), 1)
  end

  defp insert_page!(context_id, attrs) do
    %Page{
      context_id: context_id,
      title: attrs[:title] || "Test page",
      slug: attrs[:slug] || "test-#{:rand.uniform(999_999)}",
      body: attrs[:body] || "test body",
      page_type: attrs[:page_type] || "note",
      embedding_hash: attrs[:embedding_hash] || "hash-#{:rand.uniform(999_999)}",
      embedding: attrs[:embedding]
    }
    |> Repo.insert!()
  end

  defp matching_vector, do: List.duplicate(1.0, 1024)

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

  defp configure_inference do
    original = Application.get_env(:dran, :inference)

    Application.put_env(:dran, :inference,
      base_url: "http://localhost:8000/v1",
      api_key: "test-key",
      chat_model: "test-chat-model",
      embedding_model: "Qwen3-Embedding",
      rerank_model: "Qwen3-Reranker",
      markitdown_model: "MarkItDown",
      timeout: 5_000,
      use_rerank: false,
      req_plug: {Req.Test, Dran.Inference.Client},
      schedule_async: false
    )

    ensure_queue_started(:chat)
    ensure_queue_started(:embed)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:dran, :inference)
      else
        Application.put_env(:dran, :inference, original)
      end
    end)
  end

  @doc """
  Stub that returns a plain-content chat completion (no tool_calls).

  The agent engine's `parse_response` cannot extract a tool call from this,
  so the agent session fails → server falls back to Chat.Brain.
  """
  defp stub_inference(reply_text) do
    Req.Test.stub(Dran.Inference.Client, fn conn ->
      case conn.request_path do
        "/v1/embeddings" ->
          Req.Test.json(conn, %{
            "object" => "list",
            "data" => [
              %{"object" => "embedding", "index" => 0, "embedding" => List.duplicate(1.0, 1024)}
            ]
          })

        "/v1/chat/completions" ->
          Req.Test.json(conn, %{
            "id" => "chat-1",
            "object" => "chat.completion",
            "model" => "test-chat-model",
            "choices" => [
              %{
                "message" => %{
                  "role" => "assistant",
                  "content" => reply_text
                }
              }
            ],
            "usage" => %{"total_tokens" => 50}
          })
      end
    end)
  end

  @doc """
  Stub that returns an HTTP error for the agent's tool-calling request,
  forcing the agent session to fail. The Brain fallback path still works
  because it uses a simpler payload without tools.
  """
  defp stub_agent_error(reply_text) do
    Req.Test.stub(Dran.Inference.Client, fn conn ->
      case conn.request_path do
        "/v1/embeddings" ->
          Req.Test.json(conn, %{
            "object" => "list",
            "data" => [
              %{"object" => "embedding", "index" => 0, "embedding" => List.duplicate(1.0, 1024)}
            ]
          })

        "/v1/chat/completions" ->
          # Check if this is an agent request (has tools) or a Brain request
          body = conn.body_params || %{}

          if Map.has_key?(body, "tools") do
            # Agent request — return error
            conn
            |> Plug.Conn.put_status(500)
            |> Req.Test.json(%{"error" => "model overloaded"})
          else
            # Brain fallback request — return plain content
            Req.Test.json(conn, %{
              "id" => "chat-brain-1",
              "object" => "chat.completion",
              "model" => "test-chat-model",
              "choices" => [
                %{
                  "message" => %{
                    "role" => "assistant",
                    "content" => reply_text
                  }
                }
              ],
              "usage" => %{"total_tokens" => 50}
            })
          end
      end
    end)
  end

  @doc """
  Stub that returns a `done` tool call so the agent loop completes
  successfully on the first step.

  The agent calls `done` with the given summary, and the engine marks
  the session as `done`.
  """
  defp stub_inference_done_tool(summary) do
    Req.Test.stub(Dran.Inference.Client, fn conn ->
      case conn.request_path do
        "/v1/embeddings" ->
          Req.Test.json(conn, %{
            "object" => "list",
            "data" => [
              %{"object" => "embedding", "index" => 0, "embedding" => List.duplicate(1.0, 1024)}
            ]
          })

        "/v1/chat/completions" ->
          Req.Test.json(conn, %{
            "id" => "chat-done-1",
            "object" => "chat.completion",
            "model" => "test-chat-model",
            "choices" => [
              %{
                "message" => %{
                  "role" => "assistant",
                  "content" => "",
                  "tool_calls" => [
                    %{
                      "id" => "call_done",
                      "type" => "function",
                      "function" => %{
                        "name" => "done",
                        "arguments" => Jason.encode!(%{"summary" => summary})
                      }
                    }
                  ]
                }
              }
            ],
            "usage" => %{"total_tokens" => 50}
          })
      end
    end)
  end

  defp start_server(context_id, user, opts \\ []) do
    {:ok, pid} =
      Server.start_link(
        context_id: context_id,
        user: user,
        page_slug: opts[:page_slug],
        sandbox_owner: self()
      )

    # Allow the GenServer process to use the Req.Test stub
    Req.Test.allow(Dran.Inference.Client, self(), pid)
    {:ok, pid}
  end

  # ── Tests: fallback path (agent fails → Brain is used) ────────────────────

  describe "send_message/2 — fallback to Chat.Brain" do
    setup do
      configure_inference()
      # Shared mode so the agent task (spawned by Task.Supervisor) can
      # also access the Req.Test stub.
      Req.Test.set_req_test_to_shared()

      context = ensure_context!()

      _page =
        insert_page!(context.id,
          title: "Elixir",
          slug: "elixir",
          body: "Elixir is a functional language.",
          embedding: Pgvector.new(matching_vector())
        )

      # Stub with an error response so the agent fails and the server
      # falls back to Chat.Brain. The Brain path uses the same stub but
      # only hits /v1/embeddings and /v1/chat/completions for the fallback.
      stub_agent_error("Elixir es funcional [elixir].")
      {:ok, context: context}
    end

    test "returns a reply and sources via Brain fallback", %{context: ctx} do
      {:ok, pid} = start_server(ctx.id, "alice")
      assert {:ok, reply, sources} = Server.send_message(pid, "What is Elixir?")
      assert reply =~ "Elixir es funcional"
      assert length(sources) == 1
      assert hd(sources)["slug"] == "elixir"
    end

    test "history accumulates messages", %{context: ctx} do
      {:ok, pid} = start_server(ctx.id, "bob")
      {:ok, _reply, _sources} = Server.send_message(pid, "What is Elixir?")

      history = Server.history(pid)
      assert length(history) == 2

      [user_msg, assistant_msg] = history
      assert user_msg["role"] == "user"
      assert user_msg["content"] == "What is Elixir?"
      assert assistant_msg["role"] == "assistant"
      assert assistant_msg["content"] =~ "Elixir es funcional"
      assert assistant_msg["sources"] != nil
    end
  end

  # ── Tests: agent success path ─────────────────────────────────────────────

  describe "send_message/2 — copilot agent success" do
    setup do
      configure_inference()
      # Shared mode so the agent task (spawned by Task.Supervisor) can
      # also access the Req.Test stub and the shared DB sandbox.
      Req.Test.set_req_test_to_shared()

      context = ensure_context!()

      _page =
        insert_page!(context.id,
          title: "Elixir",
          slug: "elixir",
          body: "Elixir is a functional language.",
          embedding: Pgvector.new(matching_vector())
        )

      # The stub returns a `done` tool call immediately, so the agent
      # loop completes on the first step with the given summary.
      stub_inference_done_tool("Elixir es un lenguaje funcional [elixir].")
      {:ok, context: context}
    end

    test "returns the agent's summary as reply", %{context: ctx} do
      {:ok, pid} = start_server(ctx.id, "agent-user")
      assert {:ok, reply, _sources} = Server.send_message(pid, "What is Elixir?")
      assert reply =~ "Elixir es un lenguaje funcional"
    end

    test "history records the agent reply", %{context: ctx} do
      {:ok, pid} = start_server(ctx.id, "agent-hist")
      {:ok, reply, _sources} = Server.send_message(pid, "What is Elixir?")

      history = Server.history(pid)
      assert length(history) == 2

      [user_msg, assistant_msg] = history
      assert user_msg["role"] == "user"
      assert user_msg["content"] == "What is Elixir?"
      assert assistant_msg["role"] == "assistant"
      assert assistant_msg["content"] == reply
    end
  end

  # ── Tests: clear / persistence (fallback path) ────────────────────────────

  describe "clear/1" do
    setup do
      configure_inference()
      Req.Test.set_req_test_to_shared()

      context = ensure_context!()

      _page =
        insert_page!(context.id,
          title: "Elixir",
          slug: "elixir",
          body: "Elixir is a functional language.",
          embedding: Pgvector.new(matching_vector())
        )

      stub_inference("Elixir es funcional [elixir].")
      {:ok, context: context}
    end

    test "empties the history", %{context: ctx} do
      {:ok, pid} = start_server(ctx.id, "carol")
      {:ok, _reply, _sources} = Server.send_message(pid, "What is Elixir?")
      assert length(Server.history(pid)) == 2

      :ok = Server.clear(pid)
      assert Server.history(pid) == []
    end
  end

  describe "persistence" do
    setup do
      configure_inference()
      Req.Test.set_req_test_to_shared()

      context = ensure_context!()

      _page =
        insert_page!(context.id,
          title: "Elixir",
          slug: "elixir",
          body: "Elixir is a functional language.",
          embedding: Pgvector.new(matching_vector())
        )

      stub_inference("Elixir es funcional [elixir].")
      {:ok, context: context}
    end

    test "history is loaded from DB after stop + start", %{context: ctx} do
      # First session: send a message
      {:ok, pid} = start_server(ctx.id, "dave")
      {:ok, _reply, _sources} = Server.send_message(pid, "What is Elixir?")
      assert length(Server.history(pid)) == 2

      # Stop the server
      GenServer.stop(pid)

      # Verify the session was persisted
      session = Repo.get_by!(Session, context_id: ctx.id, user: "dave")
      persisted_items = session.messages["items"]
      assert length(persisted_items) == 2

      # Start a new server for the same (context, user) — should load from DB
      {:ok, pid2} = start_server(ctx.id, "dave")
      history = Server.history(pid2)
      assert length(history) == 2

      [user_msg, assistant_msg] = history
      assert user_msg["content"] == "What is Elixir?"
      assert assistant_msg["content"] =~ "Elixir es funcional"

      GenServer.stop(pid2)
    end
  end
end
