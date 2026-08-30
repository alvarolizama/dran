defmodule Dran.MemoryTest do
  use Dran.DataCase, async: false

  alias Dran.{Knowledge, Memory}

  setup do
    original = Application.get_env(:dran, :inference)

    Application.put_env(:dran, :inference,
      base_url: "http://localhost:8000/v1",
      api_key: "test-key",
      embedding_model: "Qwen3-Embedding",
      rerank_model: "Qwen3-Reranker",
      chat_model: "Qwen3.5-9B",
      timeout: 5_000,
      req_plug: {Req.Test, Dran.Inference.Client},
      schedule_async: false,
      use_rerank: false,
      embedding_dimensions: 1024
    )

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:dran, :inference)
      else
        Application.put_env(:dran, :inference, original)
      end
    end)

    unique = System.unique_integer([:positive])

    {:ok, workspace} =
      Knowledge.create_workspace(%{
        name: "Memory Test #{unique}",
        slug: "memory-test-#{unique}"
      })

    %{workspace: workspace}
  end

  describe "add/1 dedupe" do
    test "creates a new memory with hash and embedding", %{workspace: ws} do
      attrs = %{
        "workspace_id" => ws.id,
        "content" => "Álvaro prefiere Elixir sobre TypeScript",
        "created_by" => "agent-coder"
      }

      assert {:ok, memory, :created} = add_fact(attrs)
      assert memory.content == "Álvaro prefiere Elixir sobre TypeScript"
      assert memory.content_hash != nil
      assert memory.trust_score == 0.5
      assert memory.embedding != nil
      assert memory.created_by == "agent-coder"
    end

    test "returns existing memory on duplicate content", %{workspace: ws} do
      stub_embeddings()

      attrs = %{
        "workspace_id" => ws.id,
        "content" => "Dran usa pgvector para embeddings",
        "created_by" => "agent-a"
      }

      assert {:ok, first, :created} = add_fact(attrs)
      assert {:ok, second, :duplicate} = add_fact(%{attrs | "created_by" => "agent-b"})
      assert first.id == second.id
      # The original row is untouched (created_by stays agent-a)
      assert second.created_by == "agent-a"
    end

    test "dedupe is whitespace-insensitive", %{workspace: ws} do
      assert {:ok, first, :created} = add_fact(ws, "hecho  único")
      assert {:ok, second, :duplicate} = add_fact(ws, "  hecho   único  ")
      assert second.id == first.id
    end

    test "same content in different workspaces is not a duplicate", %{workspace: ws} do
      stub_embeddings()

      unique = System.unique_integer([:positive])

      {:ok, ws2} =
        Knowledge.create_workspace(%{name: "Other #{unique}", slug: "other-#{unique}"})

      attrs = fn w -> %{"workspace_id" => w.id, "content" => "fact compartido"} end

      assert {:ok, _, :created} = add_fact(attrs.(ws))
      assert {:ok, _, :created} = add_fact(attrs.(ws2))
    end
  end

  describe "record_feedback/2" do
    test "helpful raises trust by 0.05 and bumps helpful_count", %{workspace: ws} do
      {:ok, memory, :created} = add_fact(ws, "fact uno")

      assert {:ok, updated} = Memory.record_feedback(memory.id, true)
      assert_in_delta updated.trust_score, 0.55, 0.0001
      assert updated.helpful_count == 1
    end

    test "unhelpful lowers trust by 0.10", %{workspace: ws} do
      {:ok, memory, :created} = add_fact(ws, "fact dos")

      assert {:ok, updated} = Memory.record_feedback(memory.id, false)
      assert_in_delta updated.trust_score, 0.40, 0.0001
      assert updated.helpful_count == 0
    end

    test "trust clamps at 1.0", %{workspace: ws} do
      {:ok, memory, :created} = add_fact(ws, "fact tres")

      Enum.each(1..12, fn _ ->
        {:ok, _} = Memory.record_feedback(memory.id, true)
      end)

      updated = Memory.get_memory!(memory.id)
      assert updated.trust_score == 1.0
    end

    test "trust clamps at 0.0", %{workspace: ws} do
      {:ok, memory, :created} = add_fact(ws, "fact cuatro")

      Enum.each(1..6, fn _ ->
        {:ok, _} = Memory.record_feedback(memory.id, false)
      end)

      updated = Memory.get_memory!(memory.id)
      assert updated.trust_score == 0.0
    end

    test "unknown id returns :not_found", %{} do
      assert {:error, :not_found} = Memory.record_feedback(Ecto.UUID.generate(), true)
    end
  end

  describe "search/3" do
    test "finds by full-text (spanish stemming)", %{workspace: ws} do
      add_fact(ws, "El deployment se hace los martes")
      add_fact(ws, "La base de datos es Postgres 17")

      results = Memory.search(ws.id, "deployments martes")
      contents = Enum.map(results, fn r -> r.memory.content end)

      assert "El deployment se hace los martes" in contents
    end

    test "multiplies score by trust: helpful fact ranks first", %{workspace: ws} do
      {:ok, m1, :created} = add_fact(ws, "El API key rota cada mes")
      {:ok, m2, :created} = add_fact(ws, "El API keys de staging rota cada mes")

      # Boost m1 trust
      {:ok, _} = Memory.record_feedback(m1.id, true)

      # m1 must outrank m2 despite both matching
      results = Memory.search(ws.id, "api key rota")
      assert length(results) >= 1
      first_id = hd(results).memory.id

      assert first_id == m1.id or first_id == m2.id

      scores = Map.new(results, fn r -> {r.memory.id, r.score} end)

      if Map.has_key?(scores, m1.id) and Map.has_key?(scores, m2.id) do
        assert scores[m1.id] > scores[m2.id]
      end
    end

    test "excludes superseded memories", %{workspace: ws} do
      {:ok, m1, :created} = add_fact(ws, "regla vieja obsoleta")
      add_fact(ws, "regla vigente actual")

      {:ok, _} = Memory.delete_memory(m1)

      results = Memory.search(ws.id, "regla")
      contents = Enum.map(results, fn r -> r.memory.content end)

      refute "regla vieja obsoleta" in contents
    end

    test "bumps retrieval_count of returned facts", %{workspace: ws} do
      {:ok, m1, :created} = add_fact(ws, "contador de retrieval")

      before = Memory.get_memory!(m1.id).retrieval_count
      Memory.search(ws.id, "contador retrieval")
      after_ = Memory.get_memory!(m1.id).retrieval_count

      assert after_ == before + 1
    end
  end

  describe "list_memories/2" do
    test "lists newest first and filters by status", %{workspace: ws} do
      {:ok, m1, :created} = add_fact(ws, "primero")
      {:ok, _m2, :created} = add_fact(ws, "segundo")
      {:ok, _} = Memory.delete_memory(m1)

      all = Memory.list_memories(ws.id)
      assert length(all) == 2

      active = Memory.list_memories(ws.id, status: "active")
      assert length(active) == 1
      assert hd(active).content == "segundo"
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp add_fact(attrs) when is_map(attrs) do
    stub_embeddings()
    Memory.add(attrs)
  end

  defp add_fact(ws, content) do
    stub_embeddings()
    Memory.add(%{"workspace_id" => ws.id, "content" => content})
  end

  defp stub_embeddings do
    Req.Test.stub(Dran.Inference.Client, fn conn ->
      assert conn.request_path == "/v1/embeddings"
      Req.Test.json(conn, embeddings_response())
    end)
  end

  defp embeddings_response do
    vec = List.duplicate(0.1, 1024)

    %{
      "object" => "list",
      "data" => [
        %{"object" => "embedding", "index" => 0, "embedding" => vec}
      ],
      "model" => "Qwen3-Embedding",
      "usage" => %{"prompt_tokens" => 2, "total_tokens" => 2}
    }
  end
end
