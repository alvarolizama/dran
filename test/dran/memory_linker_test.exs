defmodule Dran.MemoryLinkerTest do
  use Dran.DataCase, async: false

  alias Dran.{Knowledge, Repo}
  alias Dran.MemoryLinker

  # Synthetic 1024-dim vectors, same scheme as the memory_test stubs: one-hot
  # on a phash2-derived axis. Same-ish text → same axis; different → cosine
  # distance 1.0 (orthogonal), above any threshold.
  @dim 1024

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
      embedding_dimensions: @dim
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
        name: "Linker Test #{unique}",
        slug: "linker-test-#{unique}"
      })

    %{workspace: workspace}
  end

  describe "link_to_pages/1" do
    test "links a memory to pages with a close embedding", %{workspace: ws} do
      # Page and memory share the embedding axis → distance ~0.0, under the
      # default long threshold (0.28).
      axis = 7

      page = insert_page!(ws, "close-page", axis)
      insert_page!(ws, "far-page", 999)

      memory = insert_memory!(ws, "axis-7 fact", axis)

      assert {:ok, 1} = MemoryLinker.link_to_pages(memory)

      relation =
        Repo.get_by(Dran.Relation,
          source_id: memory.id,
          source_type: "memory",
          target_id: page.id,
          target_type: "page"
        )

      assert relation != nil
      assert relation.relation_type == "informs"
    end

    test "memory without embedding links nothing", %{workspace: ws} do
      memory = insert_memory!(ws, "plain fact", nil)
      assert {:ok, 0} = MemoryLinker.link_to_pages(memory)
    end

    test "caps at max_links relations", %{workspace: ws} do
      # 5 pages on the SAME axis as the memory — all equidistant at ~0.0.
      for i <- 1..5, do: insert_page!(ws, "cap-page-#{i}", 42)
      memory = insert_memory!(ws, "axis-42 fact", 42)

      assert {:ok, created} = MemoryLinker.link_to_pages(memory)
      assert created == MemoryLinker.max_links()
    end

    test "re-running never duplicates (idempotent)", %{workspace: ws} do
      insert_page!(ws, "idem-page", 3)
      memory = insert_memory!(ws, "axis-3 fact", 3)

      assert {:ok, 1} = MemoryLinker.link_to_pages(memory)
      assert {:ok, 0} = MemoryLinker.link_to_pages(memory)

      count =
        Repo.aggregate(
          from(r in Dran.Relation,
            where: r.source_id == ^memory.id and r.source_type == "memory"
          ),
          :count
        )

      assert count == 1
    end

    test "workspace isolation: only same-workspace pages link", %{workspace: ws} do
      unique = System.unique_integer([:positive])

      {:ok, ws2} =
        Knowledge.create_workspace(%{name: "Other #{unique}", slug: "other-linker-#{unique}"})

      # Close page lives in ANOTHER workspace → must not link.
      insert_page!(ws2, "foreign-close-page", 11)
      memory = insert_memory!(ws, "axis-11 fact", 11)

      assert {:ok, 0} = MemoryLinker.link_to_pages(memory)
    end
  end

  describe "backfill/1" do
    test "links existing memories and reports counts", %{workspace: ws} do
      insert_page!(ws, "bf-page", 5)
      insert_memory!(ws, "axis-5 fact", 5)

      assert {1, 1} = MemoryLinker.backfill(ws.id)

      # Second pass: nothing new.
      assert {1, 0} = MemoryLinker.backfill(ws.id)
    end
  end

  describe "goal propagation" do
    test "memory informs the goal its linked page is part_of", %{workspace: ws} do
      page = insert_page!(ws, "goal-page", 21)

      {:ok, goal} =
        Dran.Repo.insert(%Dran.Goals.Goal{
          workspace_id: ws.id,
          title: "Linked Goal",
          slug: "linked-goal-#{System.unique_integer([:positive])}"
        })

      {:ok, _} =
        Dran.Goals.link_note(goal, page)

      memory = insert_memory!(ws, "axis-21 fact", 21)

      assert {:ok, created} = MemoryLinker.link_to_pages(memory)
      # 1 page edge + 1 propagated goal edge
      assert created == 2

      assert Repo.get_by(Dran.Relation,
               source_id: memory.id,
               source_type: "memory",
               target_id: goal.id,
               target_type: "goal"
             ) != nil
    end
  end

  describe "run_scheduled/0" do
    test "re-links and sweeps stale informs edges", %{workspace: ws} do
      page = insert_page!(ws, "sched-page", 31)
      memory = insert_memory!(ws, "axis-31 fact", 31)

      # A superseded memory holding a stale edge.
      stale = insert_memory!(ws, "stale fact", 31)
      {:ok, _} = MemoryLinker.link_to_pages(stale)
      stale |> Ecto.Changeset.change(status: "superseded") |> Repo.update!()

      report = MemoryLinker.run_scheduled()

      assert report =~ "# Memory re-link"
      assert report =~ "Memories seen 1"
      assert report =~ "informs created 1"

      # The active memory got its edge; the superseded one lost it.
      assert Repo.get_by(Dran.Relation, source_id: memory.id, source_type: "memory") != nil
      refute Repo.get_by(Dran.Relation, source_id: stale.id, source_type: "memory")
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp insert_page!(ws, slug, axis) do
    %Dran.Knowledge.Page{
      workspace_id: ws.id,
      title: slug,
      slug: slug,
      body: "body #{slug}",
      page_type: "note",
      embedding: Pgvector.new(one_hot(axis))
    }
    |> Repo.insert!()
  end

  defp insert_memory!(ws, content, axis) do
    %Dran.Memory{
      workspace_id: ws.id,
      content: content,
      content_hash: Dran.Memory.content_hash(content),
      embedding: axis && Pgvector.new(one_hot(axis))
    }
    |> Repo.insert!()
  end

  defp one_hot(axis) do
    List.duplicate(0.0, axis) ++ [1.0] ++ List.duplicate(0.0, @dim - axis - 1)
  end
end
