defmodule Dran.Brain.PageAugmenterTest do
  use Dran.DataCase, async: false

  alias Dran.Brain
  alias Dran.Brain.Page
  alias Dran.Brain.PageAugmenter

  setup do
    original = Application.get_env(:dran, :inference)

    # Start the inference queue registry + queue for :embed capability
    case Registry.start_link(keys: :unique, name: Dran.Inference.QueueRegistry) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    case Dran.Inference.Queue.start_link(capability: :embed) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    case Dran.Inference.Queue.start_link(capability: :chat) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:dran, :inference)
      else
        Application.put_env(:dran, :inference, original)
      end
    end)

    :ok
  end

  test "run/1 skips when inference is not configured" do
    Application.put_env(:dran, :inference, nil)

    context = Brain.get_workspace_by_slug("personal")

    {:ok, page} =
      Brain.create_page(%{
        workspace_id: context.id,
        title: "Standalone note",
        slug: "standalone-note",
        body: "No inference available.",
        page_type: "note"
      })

    assert :ok = PageAugmenter.run(page)

    assert %{
             outbound: [],
             inbound: []
           } = Brain.list_relations_for_page(page.id)
  end

  test "run/1 enriches summary and creates high-confidence auto-relations" do
    Application.put_env(:dran, :inference, nil)

    context = Brain.get_workspace_by_slug("personal")

    {:ok, target} =
      Brain.create_page(%{
        workspace_id: context.id,
        title: "Phoenix framework",
        slug: "phoenix-framework",
        body: "Phoenix is a web framework for Elixir.",
        page_type: "note"
      })

    target
    |> Ecto.Changeset.change(
      embedding: Pgvector.new(List.duplicate(0.1, 1024)),
      embedding_hash: "hash"
    )
    |> Dran.Repo.update!()

    {:ok, page} =
      Brain.create_page(%{
        workspace_id: context.id,
        title: "My Phoenix project",
        slug: "my-phoenix-project",
        body: "I am building a web app with Phoenix.",
        page_type: "note"
      })

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

    Req.Test.stub(Dran.Inference.Client, fn conn ->
      case conn.request_path do
        "/v1/embeddings" ->
          Req.Test.json(conn, %{
            "object" => "list",
            "data" => [
              %{"object" => "embedding", "index" => 0, "embedding" => List.duplicate(0.1, 1024)}
            ]
          })

        "/v1/chat/completions" ->
          Req.Test.json(conn, %{
            "id" => "chat-test",
            "object" => "chat.completion",
            "model" => "Qwen3.5-9B",
            "choices" => [
              %{
                "index" => 0,
                "message" => %{
                  "role" => "assistant",
                  "content" =>
                    ~s({"summary": "Building a Phoenix web app", "tags": ["phoenix"], "entities": [], "links": ["phoenix-framework"]})
                },
                "finish_reason" => "stop"
              }
            ]
          })
      end
    end)

    assert :ok = PageAugmenter.run(page)

    refreshed = Dran.Repo.get!(Page, page.id)
    assert refreshed.summary == "Building a Phoenix web app"
    assert "phoenix" in refreshed.tags

    %{outbound: outbound} = Brain.list_relations_for_page(page.id)
    assert Enum.any?(outbound, &(&1.target_id == target.id and &1.relation_type == "semantic"))
  end

  # ── Task 3.1: dynamic threshold by body length ──

  describe "semantic_threshold/1" do
    test "returns 0.15 for short bodies (<500 chars)" do
      page = %Page{body: String.duplicate("a", 499)}
      assert PageAugmenter.semantic_threshold(page) == 0.15
    end

    test "returns 0.28 for long bodies (>4000 chars)" do
      page = %Page{body: String.duplicate("a", 4001)}
      assert PageAugmenter.semantic_threshold(page) == 0.28
    end

    test "returns 0.22 for mid-length bodies" do
      page = %Page{body: String.duplicate("a", 2000)}
      assert PageAugmenter.semantic_threshold(page) == 0.22
    end
  end

  # Helper: build a 1024-dim unit vector at a target cosine distance from e1.
  # distance d  =>  cos(theta) = 1 - d  =>  v = [1-d, sqrt(1-(1-d)^2), 0, ...]
  defp vector_at_distance(d) do
    cos = 1.0 - d
    sin = :math.sqrt(max(0.0, 1.0 - cos * cos))
    [cos, sin] ++ List.duplicate(0.0, 1022)
  end

  # Reference vector the embeddings stub returns for the source page.
  defp reference_vector, do: [1.0, 0.0] ++ List.duplicate(0.0, 1022)

  defp stub_embeddings_chat do
    Req.Test.stub(Dran.Inference.Client, fn conn ->
      case conn.request_path do
        "/v1/embeddings" ->
          Req.Test.json(conn, %{
            "object" => "list",
            "data" => [
              %{"object" => "embedding", "index" => 0, "embedding" => reference_vector()}
            ]
          })

        "/v1/chat/completions" ->
          Req.Test.json(conn, %{
            "id" => "chat-test",
            "object" => "chat.completion",
            "model" => "Qwen3.5-9B",
            "choices" => [
              %{
                "index" => 0,
                "message" => %{
                  "role" => "assistant",
                  "content" => ~s({"summary": "stub", "tags": [], "entities": [], "links": []})
                },
                "finish_reason" => "stop"
              }
            ]
          })
      end
    end)
  end

  defp enable_inference do
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
  end

  defp set_embedding(page, vector) do
    page
    |> Ecto.Changeset.change(
      embedding: Pgvector.new(vector),
      embedding_hash: "hash-#{:erlang.phash2(vector)}"
    )
    |> Dran.Repo.update!()
  end

  test "run/1 does NOT create relation for short page with neighbor at distance 0.18" do
    # Short body (<500 chars) → threshold 0.15. Neighbor at 0.18 > 0.15, no edge.
    enable_inference()
    stub_embeddings_chat()

    context = Brain.get_workspace_by_slug("personal")

    {:ok, target} =
      Brain.create_page(%{
        workspace_id: context.id,
        title: "Short neighbor",
        slug: "short-neighbor",
        body: "neighbor body",
        page_type: "note"
      })

    set_embedding(target, vector_at_distance(0.18))

    {:ok, page} =
      Brain.create_page(%{
        workspace_id: context.id,
        title: "Short source",
        slug: "short-source",
        body: String.duplicate("x", 300),
        page_type: "note"
      })

    assert :ok = PageAugmenter.run(page)

    %{outbound: outbound} = Brain.list_relations_for_page(page.id)
    refute Enum.any?(outbound, &(&1.target_id == target.id))
  end

  test "run/1 creates relation for long page with neighbor at distance 0.25" do
    # Long body (>4000 chars) → threshold 0.28. Neighbor at 0.25 < 0.28, edge created.
    enable_inference()
    stub_embeddings_chat()

    context = Brain.get_workspace_by_slug("personal")

    {:ok, target} =
      Brain.create_page(%{
        workspace_id: context.id,
        title: "Long neighbor",
        slug: "long-neighbor",
        body: "neighbor body",
        page_type: "note"
      })

    set_embedding(target, vector_at_distance(0.25))

    {:ok, page} =
      Brain.create_page(%{
        workspace_id: context.id,
        title: "Long source",
        slug: "long-source",
        body: String.duplicate("y", 4001),
        page_type: "note"
      })

    assert :ok = PageAugmenter.run(page)

    %{outbound: outbound} = Brain.list_relations_for_page(page.id)
    assert Enum.any?(outbound, &(&1.target_id == target.id and &1.relation_type == "semantic"))
  end

  # ── Task 3.2: bidirectional relations ──

  test "run/1 creates both A→B and B→A semantic relations" do
    enable_inference()
    stub_embeddings_chat()

    context = Brain.get_workspace_by_slug("personal")

    {:ok, target} =
      Brain.create_page(%{
        workspace_id: context.id,
        title: "Bidirectional target",
        slug: "bidir-target",
        body: "neighbor body",
        page_type: "note"
      })

    set_embedding(target, vector_at_distance(0.10))

    {:ok, page} =
      Brain.create_page(%{
        workspace_id: context.id,
        title: "Bidirectional source",
        slug: "bidir-source",
        body: String.duplicate("z", 2000),
        page_type: "note"
      })

    assert :ok = PageAugmenter.run(page)

    %{outbound: outbound} = Brain.list_relations_for_page(page.id)
    %{inbound: inbound} = Brain.list_relations_for_page(page.id)

    # A→B (page is source)
    assert Enum.any?(outbound, &(&1.target_id == target.id and &1.relation_type == "semantic"))
    # B→A (page is target)
    assert Enum.any?(inbound, &(&1.source_id == target.id and &1.relation_type == "semantic"))
  end

  # ── Task 3.3: no N+1 — multiple neighbors create correct relations ──

  test "run/1 creates correct relations for page with 3+ neighbors" do
    enable_inference()
    stub_embeddings_chat()

    context = Brain.get_workspace_by_slug("personal")

    targets =
      Enum.map(1..3, fn i ->
        {:ok, t} =
          Brain.create_page(%{
            workspace_id: context.id,
            title: "Neighbor #{i}",
            slug: "neighbor-#{i}",
            body: "neighbor body #{i}",
            page_type: "note"
          })

        set_embedding(t, vector_at_distance(0.05 + i * 0.05))
        t
      end)

    # 4th neighbor just above threshold should NOT get a relation.
    {:ok, far} =
      Brain.create_page(%{
        workspace_id: context.id,
        title: "Far neighbor",
        slug: "far-neighbor",
        body: "far body",
        page_type: "note"
      })

    set_embedding(far, vector_at_distance(0.40))

    {:ok, page} =
      Brain.create_page(%{
        workspace_id: context.id,
        title: "Multi neighbor source",
        slug: "multi-neighbor-source",
        body: String.duplicate("w", 2000),
        page_type: "note"
      })

    assert :ok = PageAugmenter.run(page)

    %{outbound: outbound} = Brain.list_relations_for_page(page.id)

    outbound_target_ids =
      outbound
      |> Enum.filter(&(&1.relation_type == "semantic"))
      |> Enum.map(& &1.target_id)
      |> MapSet.new()

    close_ids = MapSet.new(Enum.map(targets, & &1.id))

    # All 3 close neighbors got outbound edges.
    assert MapSet.subset?(close_ids, outbound_target_ids)
    # The far neighbor (distance 0.40 > 0.22) did NOT.
    refute MapSet.member?(outbound_target_ids, far.id)

    # Each close neighbor should also have an inbound edge back to the page (bidirectional).
    Enum.each(targets, fn t ->
      %{outbound: t_outbound} = Brain.list_relations_for_page(t.id)

      assert Enum.any?(t_outbound, &(&1.target_id == page.id and &1.relation_type == "semantic")),
             "expected reverse edge from #{t.slug} back to source page"
    end)
  end
end
