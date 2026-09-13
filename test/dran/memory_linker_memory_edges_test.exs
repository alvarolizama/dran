defmodule Dran.MemoryLinkerMemoryEdgesTest do
  @moduledoc """
  Covers the memory↔memory semantic layer of Dran.MemoryLinker: derivation
  at ingest, dedupe-band exclusion (similar facts merge, they don't link),
  the bidirectional sweep of dead-endpoint edges, and the batched
  related_snapshots/2 query that powers the memory UI.
  """
  use Dran.DataCase, async: false

  import Ecto.Query

  alias Dran.{Knowledge, Memory, MemoryLinker, Relation, Repo}

  setup do
    original = Application.get_env(:dran, :inference)

    Application.put_env(:dran, :inference,
      base_url: "http://localhost:8000/v1",
      api_key: "test-key",
      embedding_model: "Qwen3-Embedding",
      chat_model: "Qwen3.5-9B",
      timeout: 5_000,
      req_plug: {Req.Test, Dran.Inference.Client},
      schedule_async: false,
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
        name: "MemLink #{unique}",
        slug: "mem-link-#{unique}"
      })

    %{workspace: workspace}
  end

  # One-hot vectors: same content → same axis (similarity 1.0 → duplicate);
  # different content → orthogonal axes (similarity 0.0). To get a RELATED
  # (not duplicate) pair we give the second fact the first's axis plus an
  # orthogonal component: cosine ≈ 0.845 — below the 0.88 dedupe band and
  # above the linker threshold window (distance <= 0.28 ⟺ similarity >= 0.72).
  defp stub_embeddings_with(pairs) do
    Req.Test.stub(Dran.Inference.Client, fn conn ->
      {:ok, body, _conn} = Plug.Conn.read_body(conn)
      input = extract_embed_input(body)
      vec = Map.get(pairs, input) || one_hot(input)
      Req.Test.json(conn, embeddings_response(vec))
    end)
  end

  defp related_vector(base_content) do
    scale = :math.sqrt(1.0 / :math.pow(0.845, 2) - 1)
    base = one_hot(base_content)
    dominant_idx = Enum.find_index(base, &(&1 == 1.0))
    orth_idx = if dominant_idx == 0, do: 1, else: 0
    List.replace_at(base, orth_idx, scale)
  end

  defp one_hot(input) do
    idx = rem(:erlang.phash2(input), 1024)
    List.duplicate(0.0, idx) ++ [1.0] ++ List.duplicate(0.0, 1023 - idx)
  end

  defp extract_embed_input(body) do
    case Jason.decode(body) do
      {:ok, %{"input" => [input | _]}} when is_binary(input) -> input
      {:ok, %{"input" => input}} when is_binary(input) -> input
      _ -> ""
    end
  end

  defp embeddings_response(vec) do
    %{
      "object" => "list",
      "data" => [%{"object" => "embedding", "index" => 0, "embedding" => vec}],
      "model" => "Qwen3-Embedding",
      "usage" => %{"prompt_tokens" => 2, "total_tokens" => 2}
    }
  end

  describe "link_to_pages/1 — memory↔memory semantic edges" do
    test "derives a semantic edge between related facts at ingest", %{workspace: ws} do
      base = "Álvaro trabaja el repo dran en Elixir"
      related = "El proyecto dran usa Phoenix LiveView"
      stub_embeddings_with(%{related => related_vector(base)})

      assert {:ok, _m1, :created} = Memory.add(%{"workspace_id" => ws.id, "content" => base})
      assert {:ok, m2, :created} = Memory.add(%{"workspace_id" => ws.id, "content" => related})

      edges = semantic_memory_edges()
      assert length(edges) == 1

      # Directional: latest → earlier
      edge = hd(edges)
      assert edge.source_id == m2.id
      assert edge.target_id != m2.id
    end

    test "duplicate-band facts merge instead of linking", %{workspace: ws} do
      base = "hecho único del workspace"
      reworded = "hecho único del workspace (reworded)"
      # Same vector for both texts: hash differs (different strings) but
      # cosine 1.0 lands in the duplicate band → merge, never an edge.
      stub_embeddings_with(%{reworded => one_hot(base)})

      assert {:ok, _m1, :created} = Memory.add(%{"workspace_id" => ws.id, "content" => base})

      assert {:ok, _dupe, :duplicate} =
               Memory.add(%{"workspace_id" => ws.id, "content" => reworded})

      assert semantic_memory_edges() == []
    end

    test "unrelated facts (orthogonal) link nothing", %{workspace: ws} do
      stub_embeddings_with(%{})

      assert {:ok, _m1, :created} = Memory.add(%{"workspace_id" => ws.id, "content" => "a"})
      assert {:ok, _m2, :created} = Memory.add(%{"workspace_id" => ws.id, "content" => "b"})

      assert semantic_memory_edges() == []
    end
  end

  describe "run_scheduled/0 — bidirectional sweep" do
    test "drops semantic edges touching a superseded memory on either side", %{
      workspace: ws
    } do
      base = "hecho uno"
      related = "hecho dos relacionado"
      stub_embeddings_with(%{related => related_vector(base)})

      {:ok, m1, :created} = Memory.add(%{"workspace_id" => ws.id, "content" => base})
      {:ok, _m2, :created} = Memory.add(%{"workspace_id" => ws.id, "content" => related})

      assert length(semantic_memory_edges()) == 1

      # Supersede the TARGET (earlier) memory: the edge must go even though
      # the dead memory is not the source side.
      {:ok, _} = Memory.delete_memory(m1)
      MemoryLinker.run_scheduled()

      assert semantic_memory_edges() == []
    end
  end

  describe "related_snapshots/2" do
    test "returns neighbour content from both directions, batched", %{workspace: ws} do
      base = "hecho base común"
      related = "hecho emparentado"
      stub_embeddings_with(%{related => related_vector(base)})

      {:ok, m1, :created} = Memory.add(%{"workspace_id" => ws.id, "content" => base})
      {:ok, m2, :created} = Memory.add(%{"workspace_id" => ws.id, "content" => related})

      result = Memory.related_snapshots(ws.id, [m1.id, m2.id])

      assert [%{id: id2, content: "hecho emparentado"}] = Map.get(result, m1.id)
      assert id2 == m2.id

      assert [%{id: id1, content: content1}] = Map.get(result, m2.id)
      assert id1 == m1.id
      assert content1 == base
    end

    test "excludes superseded neighbours", %{workspace: ws} do
      base = "hecho base común"
      related = "hecho emparentado"
      stub_embeddings_with(%{related => related_vector(base)})

      {:ok, m1, :created} = Memory.add(%{"workspace_id" => ws.id, "content" => base})
      {:ok, m2, :created} = Memory.add(%{"workspace_id" => ws.id, "content" => related})
      {:ok, _} = Memory.delete_memory(m2)

      result = Memory.related_snapshots(ws.id, [m1.id])
      assert Map.get(result, m1.id, []) == []
    end
  end

  describe "graph_data/2 — memory↔memory edges in the 3D graph" do
    test "renders semantic edges between memory nodes", %{workspace: ws} do
      base = "nodo grafo a"
      related = "nodo grafo b emparentado"
      stub_embeddings_with(%{related => related_vector(base)})

      {:ok, _m1, :created} = Memory.add(%{"workspace_id" => ws.id, "content" => base})
      {:ok, _m2, :created} = Memory.add(%{"workspace_id" => ws.id, "content" => related})

      data = Knowledge.graph_data(ws.id)
      types = Enum.map(data.edges, & &1.type)

      assert "semantic" in types
    end
  end

  defp semantic_memory_edges do
    from(r in Relation,
      where:
        r.relation_type == "semantic" and r.source_type == "memory" and
          r.target_type == "memory"
    )
    |> Repo.all()
  end
end
