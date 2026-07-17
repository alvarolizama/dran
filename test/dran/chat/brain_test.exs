defmodule Dran.Chat.BrainTest do
  use Dran.DataCase, async: false

  alias Dran.Chat.Brain, as: ChatBrain
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

  # The query embedding stub returns all-1.0. The "matching" page uses the same
  # vector (distance 0); the "far" page uses an orthogonal vector (distance ~1).
  defp matching_vector, do: List.duplicate(1.0, 1024)
  defp far_vector, do: [1.0 | List.duplicate(0.0, 1023)]

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

  defp configure_inference(opts \\ []) do
    original = Application.get_env(:dran, :inference)

    base =
      [
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
      ]
      |> Keyword.merge(opts)

    Application.put_env(:dran, :inference, base)
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

  # ── Tests ─────────────────────────────────────────────────────────────────

  describe "answer/4 with inference disabled" do
    setup do
      original = Application.get_env(:dran, :inference)
      Application.put_env(:dran, :inference, base_url: nil, api_key: nil, schedule_async: false)

      on_exit(fn ->
        if is_nil(original) do
          Application.delete_env(:dran, :inference)
        else
          Application.put_env(:dran, :inference, original)
        end
      end)

      context = ensure_context!()
      {:ok, context: context}
    end

    test "returns a friendly not-configured message", %{context: ctx} do
      {:ok, reply, sources} = ChatBrain.answer(ctx.id, "What is Elixir?", [])
      assert reply =~ "no está configurado"
      assert sources == []
    end
  end

  describe "answer/4 with no results" do
    setup do
      configure_inference()

      context = ensure_context!()

      # Stub: embeddings return all-zeros (no pages match), chat returns a generic answer
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
                %{"message" => %{"role" => "assistant", "content" => "No sé."}}
              ],
              "usage" => %{"total_tokens" => 10}
            })
        end
      end)

      {:ok, context: context}
    end

    test "returns no-results message when search finds nothing", %{context: ctx} do
      # No pages seeded → semantic search returns nothing
      {:ok, reply, sources} = ChatBrain.answer(ctx.id, "nonexistent topic", [])
      assert reply =~ "No encontré nada relevante"
      assert sources == []
    end
  end

  describe "answer/4 with matching pages" do
    setup do
      configure_inference()

      context = ensure_context!()

      # Seed two pages: one with a matching embedding, one far away
      _page_match =
        insert_page!(context.id,
          title: "Elixir Language",
          slug: "elixir",
          body:
            "Elixir is a functional, concurrent programming language that runs on the Erlang VM.",
          embedding: Pgvector.new(matching_vector())
        )

      _page_far =
        insert_page!(context.id,
          title: "Cooking Pasta",
          slug: "pasta",
          body: "Boil water, add salt, cook for 10 minutes.",
          embedding: Pgvector.new(far_vector())
        )

      # Stub: embeddings return all-zeros (matches the matching_vector page),
      # chat returns an answer that cites [elixir]
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
                    "content" => "Elixir es un lenguaje funcional [elixir]."
                  }
                }
              ],
              "usage" => %{"total_tokens" => 50}
            })
        end
      end)

      {:ok, context: context}
    end

    test "cites the correct source page", %{context: ctx} do
      {:ok, reply, sources} = ChatBrain.answer(ctx.id, "What is Elixir?", [])

      assert reply =~ "Elixir es un lenguaje funcional"

      # The matching page must be in the sources
      elixir_source = Enum.find(sources, &(&1["slug"] == "elixir"))
      assert elixir_source != nil
      assert elixir_source["title"] == "Elixir Language"
    end

    test "uses current_page when question references 'esta página'", %{context: ctx} do
      {:ok, reply, sources} =
        ChatBrain.answer(ctx.id, "Explícame esta página", [], current_page: "elixir")

      assert reply =~ "Elixir es un lenguaje funcional"
      # When using current_page directly, only that page is used
      assert length(sources) == 1
      assert hd(sources)["slug"] == "elixir"
    end
  end
end
