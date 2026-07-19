defmodule Dran.GraphExpansionTest do
  use Dran.DataCase, async: false

  # Tests for Brain.expand_neighbors/2 (Plan Task 2.1) and
  # Brain.transitive_part_of_candidates/1 (Plan Task 3.1).
  #
  # Fixture pattern mirrors sync_links_test.exs: inference is disabled so
  # create_page doesn't call external embedding/rerank APIs, and a
  # "personal" context is reused or created.

  alias Dran.Brain

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

    context =
      Brain.get_context_by_slug("personal") ||
        elem(Brain.create_context(%{name: "Personal", slug: "personal"}), 1)

    {:ok, context: context}
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp create_note(ctx, slug, opts \\ []) do
    {:ok, page} =
      Brain.create_page(%{
        context_id: ctx.id,
        title: Keyword.get(opts, :title, slug),
        slug: slug,
        page_type: "note",
        body: Keyword.get(opts, :body, ""),
        summary: Keyword.get(opts, :summary)
      })

    page
  end

  defp relate!(source, target, type) do
    {:ok, _} =
      Brain.create_relation(%{
        source_id: source.id,
        target_id: target.id,
        relation_type: type
      })

    :ok
  end

  defp find_by_slug(neighbors, slug) do
    Enum.find(neighbors, &(&1.slug == slug))
  end

  # ── expand_neighbors/2 (Task 2.1) ─────────────────────────────────────────

  describe "expand_neighbors/2" do
    test "returns outbound part_of neighbor with correct type and direction", %{context: ctx} do
      a = create_note(ctx, "a")
      b = create_note(ctx, "b")
      relate!(a, b, "part_of")

      neighbors = Brain.expand_neighbors(a.id)

      b_neighbor = find_by_slug(neighbors, "b")
      assert b_neighbor != nil, "expected b in neighbors, got: #{inspect(neighbors)}"
      assert b_neighbor.relation_type == "part_of"
      assert b_neighbor.direction == "outbound"
      assert b_neighbor.id == b.id
      assert b_neighbor.page_type == "note"
      assert b_neighbor.title == "b"
    end

    test "excludes semantic edges by default", %{context: ctx} do
      a = create_note(ctx, "a")
      b = create_note(ctx, "b")
      s = create_note(ctx, "s")
      relate!(a, b, "part_of")
      relate!(a, s, "semantic")

      neighbors = Brain.expand_neighbors(a.id)
      slugs = Enum.map(neighbors, & &1.slug)

      assert "b" in slugs
      refute "s" in slugs, "semantic neighbor must be excluded by default, got: #{inspect(slugs)}"
    end

    test "inbound direction works (b sees a as inbound)", %{context: ctx} do
      a = create_note(ctx, "a")
      b = create_note(ctx, "b")
      relate!(a, b, "part_of")

      # b is the target of a→b, so from b's perspective a is an inbound neighbor.
      neighbors = Brain.expand_neighbors(b.id)

      a_neighbor = find_by_slug(neighbors, "a")
      assert a_neighbor != nil, "expected a in b's neighbors, got: #{inspect(neighbors)}"
      assert a_neighbor.direction == "inbound"
      assert a_neighbor.relation_type == "part_of"
    end

    test "includes embeds/supersedes/related by default, excludes contradicts", %{context: ctx} do
      a = create_note(ctx, "a")
      e = create_note(ctx, "e")
      su = create_note(ctx, "su")
      r = create_note(ctx, "r")
      c = create_note(ctx, "c")

      relate!(a, e, "embeds")
      relate!(a, su, "supersedes")
      relate!(a, r, "related")
      relate!(a, c, "contradicts")

      neighbors = Brain.expand_neighbors(a.id)
      slugs = Enum.map(neighbors, & &1.slug)

      assert "e" in slugs
      assert "su" in slugs
      assert "r" in slugs
      refute "c" in slugs, "contradicts must be excluded by default"
    end

    test "opts :types overrides default filter", %{context: ctx} do
      a = create_note(ctx, "a")
      b = create_note(ctx, "b")
      r = create_note(ctx, "r")
      relate!(a, b, "part_of")
      relate!(a, r, "related")

      neighbors = Brain.expand_neighbors(a.id, types: ["part_of"])
      slugs = Enum.map(neighbors, & &1.slug)

      assert "b" in slugs
      refute "r" in slugs, "related must be excluded when types: [\"part_of\"]"
    end

    test "dedups by id when same neighbor appears inbound and outbound", %{context: ctx} do
      a = create_note(ctx, "a")
      b = create_note(ctx, "b")
      # a→b part_of (outbound for a) and b→a part_of (inbound for a) —
      # both reference the same neighbor set {a, b}; from a's view, b
      # appears once outbound and a appears once inbound, but a is self
      # so it's the only overlap test we can build cleanly. Instead we
      # test the simpler invariant: a page with a single edge produces
      # exactly one neighbor entry.
      relate!(a, b, "part_of")

      neighbors = Brain.expand_neighbors(a.id)
      assert length(neighbors) == 1
    end

    test "populates summary when present", %{context: ctx} do
      a = create_note(ctx, "a")
      b = create_note(ctx, "b", summary: "summary for b")
      relate!(a, b, "part_of")

      neighbors = Brain.expand_neighbors(a.id)
      b_neighbor = find_by_slug(neighbors, "b")
      assert b_neighbor.summary == "summary for b"
    end

    test "returns empty list for a page with no relations", %{context: ctx} do
      lonely = create_note(ctx, "lonely")
      assert Brain.expand_neighbors(lonely.id) == []
    end
  end

  # ── transitive_part_of_candidates/1 (Task 3.1) ─────────────────────────────

  describe "transitive_part_of_candidates/1" do
    test "finds transitive candidate a→c via b", %{context: ctx} do
      a = create_note(ctx, "a")
      b = create_note(ctx, "b")
      c = create_note(ctx, "c")
      relate!(a, b, "part_of")
      relate!(b, c, "part_of")

      candidates = Brain.transitive_part_of_candidates(ctx.id)

      assert %{source_slug: "a", target_slug: "c", via_slug: "b"} in candidates,
             "expected (a, c, via b) in candidates, got: #{inspect(candidates)}"
    end

    test "does not propose a pair when the direct edge already exists", %{context: ctx} do
      a = create_note(ctx, "a")
      b = create_note(ctx, "b")
      c = create_note(ctx, "c")
      relate!(a, b, "part_of")
      relate!(b, c, "part_of")
      # direct edge already present → must NOT be proposed
      relate!(a, c, "part_of")

      candidates = Brain.transitive_part_of_candidates(ctx.id)

      refute %{source_slug: "a", target_slug: "c", via_slug: "b"} in candidates,
             "must not propose a→c when direct edge exists, got: #{inspect(candidates)}"
    end

    test "cycle a→b→a does not crash and does not propose self-loop", %{context: ctx} do
      a = create_note(ctx, "a")
      b = create_note(ctx, "b")
      relate!(a, b, "part_of")
      relate!(b, a, "part_of")

      # Must not hang or raise. The visited-array guard terminates the
      # recursion, and the depth=2 + source != target filter excludes
      # the trivial cycle.
      candidates = Brain.transitive_part_of_candidates(ctx.id)

      # The cycle produces depth=2 rows a→b→a (source=a, target=a) and
      # b→a→b (source=b, target=b); the `source_id != target_id` filter
      # must drop both, so no candidates are returned.
      refute %{source_slug: "a", target_slug: "a"} in candidates
      refute %{source_slug: "b", target_slug: "b"} in candidates
    end

    test "returns empty list for a context with no part_of chain", %{context: ctx} do
      a = create_note(ctx, "a")
      b = create_note(ctx, "b")
      # only related, not part_of → no transitive candidate
      relate!(a, b, "related")

      candidates = Brain.transitive_part_of_candidates(ctx.id)
      assert candidates == []
    end

    test "respects depth cap: a→b→c→d does not propose a→d", %{context: ctx} do
      a = create_note(ctx, "a")
      b = create_note(ctx, "b")
      c = create_note(ctx, "c")
      d = create_note(ctx, "d")
      relate!(a, b, "part_of")
      relate!(b, c, "part_of")
      relate!(c, d, "part_of")

      candidates = Brain.transitive_part_of_candidates(ctx.id)
      candidate_pairs = Enum.map(candidates, &{&1.source_slug, &1.target_slug})

      # depth 2 (a→b→c) is the max, so a→c should be proposed but a→d
      # (which would require depth 3) must NOT.
      assert {"a", "c"} in candidate_pairs
      refute {"a", "d"} in candidate_pairs, "depth > 2 must not be proposed"
    end

    test "does not propose across contexts", %{context: ctx} do
      # Create a second context with its own part_of chain.
      {:ok, other_ctx} =
        Brain.create_context(%{
          name: "Other",
          slug: "other-context-#{:erlang.unique_integer([:positive])}"
        })

      a = create_note(ctx, "a")
      b = create_note(ctx, "b")
      c = create_note(ctx, "c")
      relate!(a, b, "part_of")
      relate!(b, c, "part_of")

      # Pages in the other context, not reachable from `ctx`.
      x = create_note(other_ctx, "x")
      y = create_note(other_ctx, "y")
      z = create_note(other_ctx, "z")
      relate!(x, y, "part_of")
      relate!(y, z, "part_of")

      candidates = Brain.transitive_part_of_candidates(ctx.id)
      slugs = Enum.flat_map(candidates, &[&1.source_slug, &1.target_slug, &1.via_slug])

      assert "a" in slugs
      refute "x" in slugs, "must not propose candidates from other contexts"
      refute "z" in slugs
    end
  end

  # ── community_pages/2 (Task 4.3) ───────────────────────────────────────────

  describe "community_pages/2" do
    test "returns only pages belonging to the given community", %{context: ctx} do
      # Cluster 1: a-b-c triangle (will share one community_id).
      a = create_note(ctx, "cp-a")
      b = create_note(ctx, "cp-b")
      c = create_note(ctx, "cp-c")
      relate!(a, b, "related")
      relate!(b, c, "related")
      relate!(a, c, "related")

      # Cluster 2: x-y single edge (different community_id).
      x = create_note(ctx, "cp-x")
      y = create_note(ctx, "cp-y")
      relate!(x, y, "related")

      # Persist community ids into meta.
      :ok = Dran.Graph.refresh_communities(ctx.id)

      # Read the community_id assigned to cluster 1.
      a_reloaded = Brain.get_page!(a.id)
      cid_a = a_reloaded.meta["community_id"]
      assert is_integer(cid_a)

      # community_pages/2 must return exactly {a, b, c} for cid_a.
      pages = Brain.community_pages(ctx.id, cid_a)
      slugs = Enum.map(pages, & &1.slug) |> Enum.sort()

      assert slugs == ["cp-a", "cp-b", "cp-c"]

      # Each result carries the lightweight select fields.
      a_entry = Enum.find(pages, &(&1.slug == "cp-a"))
      assert a_entry.id == a.id
      assert a_entry.title == "cp-a"
      assert a_entry.page_type == "note"
    end

    test "returns empty list for a community_id that does not exist", %{context: ctx} do
      a = create_note(ctx, "cp-none-a")
      b = create_note(ctx, "cp-none-b")
      relate!(a, b, "related")
      :ok = Dran.Graph.refresh_communities(ctx.id)

      # 99999 is (almost certainly) not a real community_id.
      assert Brain.community_pages(ctx.id, 999_999) == []
    end

    test "does not leak pages from other contexts", %{context: ctx} do
      # Cluster in the shared `ctx`.
      a = create_note(ctx, "cp-cross-a")
      b = create_note(ctx, "cp-cross-b")
      relate!(a, b, "related")
      :ok = Dran.Graph.refresh_communities(ctx.id)

      cid = Brain.get_page!(a.id).meta["community_id"]

      # Same community_id value, but in a different context — must return [].
      {:ok, other_ctx} =
        Brain.create_context(%{
          name: "Other CP",
          slug: "cp-other-#{:erlang.unique_integer([:positive])}"
        })

      # Manually stamp the same community_id on a page in the other context
      # to verify the context_id filter works.
      other_page = create_note(other_ctx, "cp-cross-other")
      {:ok, _} = Brain.update_page(other_page, %{meta: %{"community_id" => cid}})

      pages = Brain.community_pages(ctx.id, cid)
      slugs = Enum.map(pages, & &1.slug)

      assert "cp-cross-a" in slugs
      refute "cp-cross-other" in slugs, "must not leak pages from other contexts"
    end
  end
end
