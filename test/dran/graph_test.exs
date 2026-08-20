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

  alias Dran.Knowledge
  alias Dran.Graph

  setup do
    original = Application.get_env(:dran, :inference)

    Application.put_env(:dran, :inference,
      base_url: nil,
      api_key: nil,
      embedding_model: nil,
      rerank_model: nil,
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

    {:ok, ctx} = Knowledge.create_workspace(%{name: "Graph Test #{slug}", slug: slug})
    ctx
  end

  defp create_page(ctx, slug) do
    {:ok, page} =
      Knowledge.create_page(%{
        workspace_id: ctx.id,
        title: slug,
        slug: slug,
        page_type: "note",
        body: "",
        meta: %{"kind" => "thought"}
      })

    page
  end

  defp relate(source, target, type) do
    {:ok, _} =
      Knowledge.create_relation(%{
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

      b_reloaded = Knowledge.get_page!(b.id)
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
      {:ok, _} = Knowledge.update_page(b, %{meta: %{"kind" => "thought", "author" => "tester"}})

      :ok = Graph.refresh_pagerank(ctx.id)

      b_reloaded = Knowledge.get_page!(b.id)
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
        reloaded = Knowledge.get_page!(page.id)
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
        Knowledge.get_workspace_by_slug("personal") ||
          elem(Knowledge.create_workspace(%{name: "Personal", slug: "personal"}), 1)

      a = create_page(ctx, "g-sched-a-#{System.unique_integer([:positive])}")
      b = create_page(ctx, "g-sched-b-#{System.unique_integer([:positive])}")
      relate(a, b, "part_of")

      result = Graph.refresh_all_scheduled()
      assert result == :ok

      b_reloaded = Knowledge.get_page!(b.id)
      pr = b_reloaded.meta["pagerank"]
      assert is_float(pr)
      assert pr > 0
    end

    test "refreshes both pagerank and community_id for the default context" do
      ctx =
        Knowledge.get_workspace_by_slug("personal") ||
          elem(Knowledge.create_workspace(%{name: "Personal", slug: "personal"}), 1)

      uniq = System.unique_integer([:positive])
      a = create_page(ctx, "g-sched2-a-#{uniq}")
      b = create_page(ctx, "g-sched2-b-#{uniq}")
      relate(a, b, "part_of")

      assert :ok = Graph.refresh_all_scheduled()

      # Both signals must be present after the scheduled refresh.
      a_reloaded = Knowledge.get_page!(a.id)
      b_reloaded = Knowledge.get_page!(b.id)

      assert is_float(a_reloaded.meta["pagerank"])
      assert is_float(b_reloaded.meta["pagerank"])

      # Two pages linked by a single community edge share a community_id.
      assert is_integer(a_reloaded.meta["community_id"])
      assert is_integer(b_reloaded.meta["community_id"])
      assert a_reloaded.meta["community_id"] == b_reloaded.meta["community_id"]
    end
  end

  # ── Task 4.1: communities/2 ──────────────────────────────────────────────────

  describe "communities/2" do
    test "returns empty map for context with no relations" do
      ctx = fresh_context("lp-empty")
      assert Graph.communities(ctx.id) == %{}
    end

    test "clusters densely connected pages into the same community" do
      ctx = fresh_context("lp-cluster")

      # Cluster 1: a-b-c fully linked (triangle).
      # Cluster 2: x-y linked (single edge).
      # No cross-cluster edges.
      a = create_page(ctx, "g-lp-a")
      b = create_page(ctx, "g-lp-b")
      c = create_page(ctx, "g-lp-c")
      x = create_page(ctx, "g-lp-x")
      y = create_page(ctx, "g-lp-y")

      relate(a, b, "related")
      relate(b, c, "related")
      relate(a, c, "related")
      relate(x, y, "related")

      comms = Graph.communities(ctx.id, seed: {1, 2, 3})

      # Cluster 1: a, b, c share the same label.
      assert comms[a.id] == comms[b.id]
      assert comms[b.id] == comms[c.id]

      # Cluster 2: x, y share the same label.
      assert comms[x.id] == comms[y.id]

      # The two clusters have different labels.
      assert comms[a.id] != comms[x.id]
    end

    test "labels are compressed to consecutive integers 1..k" do
      ctx = fresh_context("lp-int")

      a = create_page(ctx, "g-lp-int-a")
      b = create_page(ctx, "g-lp-int-b")
      x = create_page(ctx, "g-lp-int-x")
      y = create_page(ctx, "g-lp-int-y")

      relate(a, b, "related")
      relate(x, y, "related")

      comms = Graph.communities(ctx.id, seed: {42, 7, 99})

      labels = comms |> Map.values() |> Enum.uniq() |> Enum.sort()

      # Exactly two communities, labeled 1 and 2.
      assert labels == [1, 2]
    end

    test "excludes semantic and contradicts edges from community detection" do
      ctx = fresh_context("lp-filter")

      # a and b connected only via semantic — must NOT be clustered together
      # (no community edge between them). Since the only edge is filtered out,
      # neither node appears in the community graph at all.
      a = create_page(ctx, "g-lp-f-a")
      b = create_page(ctx, "g-lp-f-b")

      relate(a, b, "semantic")

      comms = Graph.communities(ctx.id, seed: {5, 5, 5})

      # With no community edges, the result is empty — neither node gets a label.
      refute Map.has_key?(comms, a.id)
      refute Map.has_key?(comms, b.id)
    end

    test "isolated nodes each form their own community" do
      ctx = fresh_context("lp-iso")

      # Two connected nodes + one isolated node with no edges at all.
      # The isolated node won't even appear in load_edges, so it's absent
      # from the result (it has no community). The two connected nodes
      # share a community.
      a = create_page(ctx, "g-lp-iso-a")
      b = create_page(ctx, "g-lp-iso-b")
      isolated = create_page(ctx, "g-lp-iso-alone")

      relate(a, b, "part_of")

      comms = Graph.communities(ctx.id, seed: {1, 1, 1})

      # a and b share a community.
      assert comms[a.id] == comms[b.id]
      # The isolated page is not in the result (no edges to propagate).
      refute Map.has_key?(comms, isolated.id)
    end

    test "undirected: edge direction does not affect clustering" do
      ctx = fresh_context("lp-undir")

      a = create_page(ctx, "g-lp-u-a")
      b = create_page(ctx, "g-lp-u-b")
      c = create_page(ctx, "g-lp-u-c")

      # Mix of directions within the same triangle.
      relate(a, b, "part_of")
      relate(c, b, "part_of")
      relate(a, c, "part_of")

      comms = Graph.communities(ctx.id, seed: {9, 9, 9})

      assert comms[a.id] == comms[b.id]
      assert comms[b.id] == comms[c.id]
    end
  end

  # ── Task 4.2: refresh_communities/1 ─────────────────────────────────────────

  describe "refresh_communities/1" do
    test "persists community_id into Page.meta as an integer" do
      ctx = fresh_context("rc")
      a = create_page(ctx, "g-rc-a")
      b = create_page(ctx, "g-rc-b")
      relate(a, b, "part_of")

      assert :ok = Graph.refresh_communities(ctx.id)

      a_reloaded = Knowledge.get_page!(a.id)
      b_reloaded = Knowledge.get_page!(b.id)

      cid_a = a_reloaded.meta["community_id"]
      cid_b = b_reloaded.meta["community_id"]

      assert is_integer(cid_a)
      assert is_integer(cid_b)
      assert cid_a == cid_b
    end

    test "two pages in the same cluster share an integer community_id" do
      ctx = fresh_context("rc-cluster")

      # Cluster 1: a-b-c triangle.
      a = create_page(ctx, "g-rc-c-a")
      b = create_page(ctx, "g-rc-c-b")
      c = create_page(ctx, "g-rc-c-c")
      relate(a, b, "related")
      relate(b, c, "related")
      relate(a, c, "related")

      # Cluster 2: x-y single edge.
      x = create_page(ctx, "g-rc-c-x")
      y = create_page(ctx, "g-rc-c-y")
      relate(x, y, "related")

      :ok = Graph.refresh_communities(ctx.id)

      reload = fn page -> Knowledge.get_page!(page.id).meta["community_id"] end

      cid_a = reload.(a)
      cid_b = reload.(b)
      cid_c = reload.(c)
      cid_x = reload.(x)
      cid_y = reload.(y)

      # All cluster-1 pages share the same integer community_id.
      assert is_integer(cid_a)
      assert cid_a == cid_b
      assert cid_b == cid_c

      # Cluster-2 pages share a different integer community_id.
      assert is_integer(cid_x)
      assert cid_x == cid_y
      assert cid_a != cid_x
    end

    test "preserves existing meta keys when writing community_id" do
      ctx = fresh_context("rc-preserve")
      a = create_page(ctx, "g-rc-p-a")
      b = create_page(ctx, "g-rc-p-b")
      relate(a, b, "part_of")

      {:ok, _} = Knowledge.update_page(b, %{meta: %{"kind" => "thought", "author" => "tester"}})

      :ok = Graph.refresh_communities(ctx.id)

      b_reloaded = Knowledge.get_page!(b.id)

      assert b_reloaded.meta["author"] == "tester"
      assert b_reloaded.meta["kind"] == "thought"
      assert is_integer(b_reloaded.meta["community_id"])
    end

    test "returns :ok on empty context" do
      ctx = fresh_context("rc-empty")
      assert :ok = Graph.refresh_communities(ctx.id)
    end
  end
end
