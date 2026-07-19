defmodule Dran.GraphTest do
  use Dran.DataCase, async: false

  # Tests for Dran.Graph (Plan Phase 1, tasks 1.2-1.5).
  #
  # Covers:
  #   - edge_weight/1: typed weights
  #   - community_edge?/1: excludes semantic / contradicts
  #   - pagerank/1: hub page ranks higher than leaves (ordering only)
  #   - refresh_pagerank/1: scores persisted into Page.meta as floats
  #
  # Same setup pattern as sync_links_test.exs: disable inference so
  # create_page doesn't call external embedding/rerank APIs. Each test
  # that touches the DB creates its OWN isolated context (rather than
  # sharing "personal") so pagerank(ctx.id) only sees the relations
  # created by that test.

  alias Dran.Brain
  alias Dran.Graph

  setup do
    original = Application.get_env(:dran, :inference)

    Application.put_env(:dran, :inference,
      base_url: nil,
      api_key: nil,
      embedding_model: nil,
      rerank_model: nil,
      markitdown_model: nil,
      timeout: 100,
      schedule_async: false
    )

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:dran, :inference)
      else
        Application.put_env(:dran, :inference, original)
      end
    end)

    :ok
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  # Create a fresh isolated context for a single test. Each context gets
  # a unique slug so tests don't collide on the shared "personal" context.
  defp fresh_context(prefix) do
    slug = "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"

    {:ok, ctx} = Brain.create_context(%{name: "Graph Test #{slug}", slug: slug})
    ctx
  end

  defp create_page(ctx, slug) do
    {:ok, page} =
      Brain.create_page(%{
        context_id: ctx.id,
        title: slug,
        slug: slug,
        page_type: "note",
        body: "",
        meta: %{"kind" => "thought"}
      })

    page
  end

  defp relate(source, target, type) do
    {:ok, _} = Brain.create_relation(%{
      source_id: source.id,
      target_id: target.id,
      relation_type: type
    })
    :ok
  end

  # ── Task 1.2: edge_weight/1 ────────────────────────────────────────────────

  describe "edge_weight/1" do
    test "returns typed weights for known types" do
      assert Graph.edge_weight("part_of") == 1.0
      assert Graph.edge_weight("embeds") == 0.8
      assert Graph.edge_weight("supersedes") == 0.7
      assert Graph.edge_weight("related") == 0.5
      assert Graph.edge_weight("contradicts") == 0.2
      assert Graph.edge_weight("semantic") == 0.1
    end

    test "defaults unknown types to 0.5" do
      assert Graph.edge_weight("unknown") == 0.5
      assert Graph.edge_weight("totally-made-up") == 0.5
    end

    test "accepts atoms by converting them to strings" do
      assert Graph.edge_weight(:part_of) == 1.0
      assert Graph.edge_weight(:semantic) == 0.1
    end
  end

  # ── Task 1.2: community_edge?/1 ────────────────────────────────────────────

  describe "community_edge?/1" do
    test "includes structural types" do
      assert Graph.community_edge?("part_of")
      assert Graph.community_edge?("embeds")
      assert Graph.community_edge?("supersedes")
      assert Graph.community_edge?("related")
    end

    test "excludes semantic and contradicts" do
      refute Graph.community_edge?("semantic")
      refute Graph.community_edge?("contradicts")
    end

    test "excludes unknown types" do
      refute Graph.community_edge?("unknown")
    end

    test "accepts atoms" do
      assert Graph.community_edge?(:part_of)
      refute Graph.community_edge?(:semantic)
    end
  end

  # ── Task 1.2: load_edges/1 ─────────────────────────────────────────────────

  describe "load_edges/1" do
    test "returns edges scoped by context with typed weights" do
      ctx = fresh_context("le")
      a = create_page(ctx, "g-le-a")
      b = create_page(ctx, "g-le-b")
      relate(a, b, "part_of")

      edges = Graph.load_edges(ctx.id)
      assert length(edges) == 1

      [edge] = edges
      assert edge.source == a.id
      assert edge.target == b.id
      assert edge.type == "part_of"
      assert edge.weight == 1.0
    end

    test "returns empty list for context with no relations" do
      ctx = fresh_context("le-empty")

      assert Graph.load_edges(ctx.id) == []
    end
  end

  # ── Task 1.3: pagerank/1 ────────────────────────────────────────────────────

  describe "pagerank/1" do
    test "returns empty map for context with no relations" do
      ctx = fresh_context("pr-empty")

      assert Graph.pagerank(ctx.id) == %{}
    end

    test "hub page with two inlinks ranks higher than the leaves" do
      ctx = fresh_context("pr-hub")
      # a -> b (part_of)
      # c -> b (part_of)
      # b receives 2 inlinks; a and c receive none.
      a = create_page(ctx, "g-pr-a")
      b = create_page(ctx, "g-pr-b")
      c = create_page(ctx, "g-pr-c")
      relate(a, b, "part_of")
      relate(c, b, "part_of")

      ranks = Graph.pagerank(ctx.id)

      # All three nodes appear in the result.
      assert Map.has_key?(ranks, a.id)
      assert Map.has_key?(ranks, b.id)
      assert Map.has_key?(ranks, c.id)

      # Ordering only: b (the hub) outranks both leaves.
      assert ranks[b.id] > ranks[a.id]
      assert ranks[b.id] > ranks[c.id]
    end

    test "scores are normalized to sum to 1" do
      ctx = fresh_context("pr-norm")
      a = create_page(ctx, "g-pr-norm-a")
      b = create_page(ctx, "g-pr-norm-b")
      c = create_page(ctx, "g-pr-norm-c")
      relate(a, b, "part_of")
      relate(c, b, "part_of")

      ranks = Graph.pagerank(ctx.id)
      sum = ranks |> Map.values() |> Enum.sum()

      assert_in_delta sum, 1.0, 1.0e-6
    end

    test "part_of transfers more authority than semantic" do
      ctx = fresh_context("pr-weight")
      # Single source s with two outbound edges of different types:
      #   s -> hub_po via part_of (weight 1.0)
      #   s -> hub_sem via semantic (weight 0.1)
      # hub_po should rank higher because part_of transfers a larger
      # share of s's score (1.0/1.1 vs 0.1/1.1).
      s = create_page(ctx, "g-pr-w-s")
      hub_po = create_page(ctx, "g-pr-w-hub-po")
      hub_sem = create_page(ctx, "g-pr-w-hub-sem")

      relate(s, hub_po, "part_of")
      relate(s, hub_sem, "semantic")

      ranks = Graph.pagerank(ctx.id)

      assert ranks[hub_po.id] > ranks[hub_sem.id]
    end
  end

  # ── Task 1.4: refresh_pagerank/1 ───────────────────────────────────────────

  describe "refresh_pagerank/1" do
    test "persists pagerank into Page.meta as a float" do
      ctx = fresh_context("rp")
      a = create_page(ctx, "g-rp-a")
      b = create_page(ctx, "g-rp-b")
      relate(a, b, "part_of")

      assert :ok = Graph.refresh_pagerank(ctx.id)

      b_reloaded = Brain.get_page!(b.id)
      pr = b_reloaded.meta["pagerank"]

      assert is_float(pr)
      assert pr > 0
    end

    test "preserves existing meta keys when writing pagerank" do
      ctx = fresh_context("rp-preserve")
      a = create_page(ctx, "g-rp-preserve-a")
      b = create_page(ctx, "g-rp-preserve-b")
      relate(a, b, "part_of")

      # Manually set an existing meta key (kind was set on create).
      {:ok, _} = Brain.update_page(b, %{meta: %{"kind" => "thought", "author" => "tester"}})

      :ok = Graph.refresh_pagerank(ctx.id)

      b_reloaded = Brain.get_page!(b.id)
      # Existing keys must survive the jsonb merge.
      assert b_reloaded.meta["author"] == "tester"
      assert b_reloaded.meta["kind"] == "thought"
      # And pagerank was added.
      assert is_float(b_reloaded.meta["pagerank"])
      assert b_reloaded.meta["pagerank"] > 0
    end

    test "all pages with relations receive a score" do
      ctx = fresh_context("rp-all")
      a = create_page(ctx, "g-rp-all-a")
      b = create_page(ctx, "g-rp-all-b")
      c = create_page(ctx, "g-rp-all-c")
      relate(a, b, "part_of")
      relate(c, b, "part_of")

      :ok = Graph.refresh_pagerank(ctx.id)

      for page <- [a, b, c] do
        reloaded = Brain.get_page!(page.id)
        pr = reloaded.meta["pagerank"]
        assert is_float(pr)
        assert pr > 0
      end
    end

    test "returns :ok on empty context" do
      ctx = fresh_context("rp-empty")

      assert :ok = Graph.refresh_pagerank(ctx.id)
    end
  end

  # ── Task 1.5: refresh_all_scheduled/0 ───────────────────────────────────────

  describe "refresh_all_scheduled/0" do
    test "refreshes pagerank for the default context" do
      # The default context is "personal". Ensure it exists, then create
      # at least one relation so there's something to rank. This test
      # depends on the default context slug being "personal" — same
      # assumption as sync_links_test.exs.
      ctx =
        Brain.get_context_by_slug("personal") ||
          elem(Brain.create_context(%{name: "Personal", slug: "personal"}), 1)

      a = create_page(ctx, "g-sched-a-#{System.unique_integer([:positive])}")
      b = create_page(ctx, "g-sched-b-#{System.unique_integer([:positive])}")
      relate(a, b, "part_of")

      result = Graph.refresh_all_scheduled()
      assert result == :ok

      b_reloaded = Brain.get_page!(b.id)
      pr = b_reloaded.meta["pagerank"]
      assert is_float(pr)
      assert pr > 0
    end
  end
end
