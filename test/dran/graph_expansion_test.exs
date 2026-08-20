defmodule Dran.GraphExpansionTest do
  use Dran.DataCase, async: false

  # Tests for Brain.transitive_part_of_candidates/1 (Plan Task 3.1) and
  # Brain.community_pages/2 (Task 4.3).
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
      Brain.get_workspace_by_slug("personal") ||
        elem(Brain.create_workspace(%{name: "Personal", slug: "personal"}), 1)

    {:ok, context: context}
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp create_note(ctx, slug, opts \\ []) do
    {:ok, page} =
      Brain.create_page(%{
        workspace_id: ctx.id,
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
        Brain.create_workspace(%{
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
        Brain.create_workspace(%{
          name: "Other CP",
          slug: "cp-other-#{:erlang.unique_integer([:positive])}"
        })

      # Manually stamp the same community_id on a page in the other context
      # to verify the workspace_id filter works.
      other_page = create_note(other_ctx, "cp-cross-other")
      {:ok, _} = Brain.update_page(other_page, %{meta: %{"community_id" => cid}})

      pages = Brain.community_pages(ctx.id, cid)
      slugs = Enum.map(pages, & &1.slug)

      assert "cp-cross-a" in slugs
      refute "cp-cross-other" in slugs, "must not leak pages from other contexts"
    end
  end
end
