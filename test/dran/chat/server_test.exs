defmodule Dran.Chat.ServerTest do
  use Dran.DataCase, async: false

  # Shared sandbox mode so the GenServer (running in a different process)
  # can see the test's DB transactions.
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

  # ── Tests ─────────────────────────────────────────────────────────────────

  describe "send_message/2" do
    setup do
      configure_inference()
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

    test "returns a reply and sources", %{context: ctx} do
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

  describe "clear/1" do
    setup do
      configure_inference()
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
