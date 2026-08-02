defmodule Dran.BrainTest do
  use Dran.DataCase, async: false

  alias Dran.Brain

  setup do
    # Disable inference so create_page doesn't call external APIs
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
      Brain.get_context_by_slug("personal") ||
        elem(Brain.create_context(%{name: "Personal", slug: "personal"}), 1)

    {:ok, context: context}
  end

  describe "disabled page types" do
    test "enabled_page_types/1 returns all types minus disabled", %{context: ctx} do
      assert Brain.enabled_page_types(ctx) == Brain.page_types()

      {:ok, ctx} = Brain.update_context_settings(ctx, %{disabled_page_types: ["todo", "goal"]})

      enabled = Brain.enabled_page_types(ctx)
      refute "todo" in enabled
      refute "goal" in enabled
      assert "note" in enabled
    end

    test "page_type_enabled?/2 reflects disabled types", %{context: ctx} do
      {:ok, ctx} = Brain.update_context_settings(ctx, %{disabled_page_types: ["reference"]})

      refute Brain.page_type_enabled?(ctx, "reference")
      assert Brain.page_type_enabled?(ctx, "note")
    end

    test "update_context_settings/2 rejects invalid page types", %{context: ctx} do
      assert {:error, changeset} =
               Brain.update_context_settings(ctx, %{disabled_page_types: ["bogus_type"]})

      assert %{disabled_page_types: [_]} = errors_on(changeset)
    end

    test "create_page/1 rejects disabled page types", %{context: ctx} do
      {:ok, ctx} = Brain.update_context_settings(ctx, %{disabled_page_types: ["query"]})

      assert {:error, :page_type_disabled} =
               Brain.create_page(%{
                 "title" => "Disabled type page",
                 "page_type" => "query",
                 "context_id" => ctx.id,
                 "body" => "should not be created"
               })

      # Enabled types still work
      assert {:ok, _page} =
               Brain.create_page(%{
                 "title" => "Enabled type page",
                 "page_type" => "note",
                 "context_id" => ctx.id,
                 "body" => "works fine"
               })
    end

    test "list_pages/1 excludes disabled page types", %{context: ctx} do
      {:ok, _todo} =
        Brain.create_page(%{
          "title" => "Hidden todo",
          "page_type" => "todo",
          "context_id" => ctx.id,
          "body" => "a todo"
        })

      {:ok, _note} =
        Brain.create_page(%{
          "title" => "Visible note",
          "page_type" => "note",
          "context_id" => ctx.id,
          "body" => "a note"
        })

      # Before disabling, todo appears
      pages = Brain.list_pages(context_id: ctx.id)
      assert Enum.any?(pages, &(&1.page_type == "todo"))

      # After disabling, todo is hidden
      {:ok, ctx} = Brain.update_context_settings(ctx, %{disabled_page_types: ["todo"]})

      pages = Brain.list_pages(context_id: ctx.id)
      refute Enum.any?(pages, &(&1.page_type == "todo"))
      assert Enum.any?(pages, &(&1.page_type == "note"))
    end
  end

  describe "create_page/1 slug derivation" do
    test "derives slug with accent normalization", %{context: ctx} do
      {:ok, page} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "Meditación",
          page_type: "note",
          body: "x"
        })

      assert page.slug == "meditacion"
    end

    test "derives slug from body first line when title is missing", %{context: ctx} do
      {:ok, page} =
        Brain.create_page(%{
          context_id: ctx.id,
          page_type: "note",
          body: "¿Qué onda con la Tántrica?\nresto del body"
        })

      assert page.slug == "que-onda-con-la-tantrica"
    end

    test "auto-deduplicates slug on collision with hex suffix", %{context: ctx} do
      {:ok, first} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "Reunión semanal",
          page_type: "note",
          body: "x"
        })

      {:ok, second} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "Reunión semanal",
          page_type: "note",
          body: "y"
        })

      assert first.slug == "reunion-semanal"
      # Second page should get a hex suffix, not a collision error
      assert second.slug =~ ~r/^reunion-semanal-[a-f0-9]{6}$/
      refute second.slug == first.slug
    end

    test "auto-deduplicates untitled pages", %{context: ctx} do
      {:ok, first} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "你好世界",
          page_type: "note",
          body: "x"
        })

      {:ok, second} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "你好世界",
          page_type: "note",
          body: "y"
        })

      # Non-ASCII titles slugify to "untitled" — both should still succeed
      # with dedup, not fail with a unique constraint error.
      assert first.slug == "untitled"
      assert second.slug =~ ~r/^untitled-[a-f0-9]{6}$/
    end

    test "respects explicit slug even if duplicate (returns error)", %{context: ctx} do
      {:ok, _} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "A",
          slug: "explicit-dup-test",
          page_type: "note"
        })

      {:error, changeset} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "B",
          slug: "explicit-dup-test",
          page_type: "note"
        })

      # When the user explicitly passes a slug, we don't auto-dedup —
      # we surface the unique constraint error so they can choose a different one.
      errors = Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)
      assert errors[:slug] || errors[:context_id]
    end
  end

  describe "embeds auto-resolution" do
    test "create_page resolves ![[embed]] into embeds relation", %{context: ctx} do
      {:ok, target_page} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "File",
          slug: "file-a",
          page_type: "note"
        })

      {:ok, note} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "Note",
          slug: "note-a",
          page_type: "note",
          body: "See ![[file-a]]"
        })

      rels = Brain.list_relations_for_page(note.id).outbound

      assert Enum.any?(rels, &(&1.relation_type == "embeds" and &1.target_id == target_page.id))
    end

    test "update_page removes stale embeds relations", %{context: ctx} do
      {:ok, a} =
        Brain.create_page(%{context_id: ctx.id, title: "A", slug: "a", page_type: "note"})

      {:ok, b} =
        Brain.create_page(%{context_id: ctx.id, title: "B", slug: "b", page_type: "note"})

      {:ok, note} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "N",
          slug: "n",
          page_type: "note",
          body: "![[a]] ![[b]]"
        })

      {:ok, note} = Brain.update_page(note, %{"body" => "only ![[a]] now"})

      targets =
        Brain.list_relations_for_page(note.id).outbound
        |> Enum.filter(&(&1.relation_type == "embeds"))
        |> Enum.map(& &1.target_id)

      assert a.id in targets
      refute b.id in targets
    end
  end

  describe "rename_slug/2" do
    test "updates embed references in other pages", %{context: ctx} do
      {:ok, art} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "Art",
          slug: "old-art",
          page_type: "note"
        })

      {:ok, note} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "N",
          slug: "n",
          page_type: "note",
          body: "![[old-art]]"
        })

      {:ok, _} = Brain.rename_slug(art, "new-art")

      note = Brain.get_page!(note.id)
      assert note.body =~ "![[new-art]]"
      refute note.body =~ "old-art"
    end

    test "embeds relation follows the renamed slug", %{context: ctx} do
      {:ok, art} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "Art2",
          slug: "old-art2",
          page_type: "note"
        })

      {:ok, note} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "N2",
          slug: "n2",
          page_type: "note",
          body: "![[old-art2]]"
        })

      {:ok, renamed} = Brain.rename_slug(art, "new-art2")
      assert renamed.slug == "new-art2"

      rels = Brain.list_relations_for_page(note.id).outbound
      assert Enum.any?(rels, &(&1.relation_type == "embeds" and &1.target_id == art.id))
    end
  end

  describe "graph_data/1" do
    test "exposes weight on edges and summary/tags on nodes", %{context: ctx} do
      {:ok, a} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "Concept A",
          slug: "concept-a",
          page_type: "concept",
          summary: "A short summary of concept A.",
          tags: ["elixir", "otp"]
        })

      {:ok, b} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "Concept B",
          slug: "concept-b",
          page_type: "concept",
          summary: "B's summary.",
          tags: ["phoenix"]
        })

      {:ok, _rel} =
        Brain.create_relation(%{
          source_id: a.id,
          target_id: b.id,
          relation_type: "related",
          weight: 0.85
        })

      graph = Brain.graph_data(ctx.id)

      # Nodes have summary and tags keys
      node_a = Enum.find(graph.nodes, &(&1.id == a.id))
      assert Map.has_key?(node_a, :summary)
      assert Map.has_key?(node_a, :tags)
      assert node_a.summary == "A short summary of concept A."
      assert node_a.tags == ["elixir", "otp"]

      # Edges expose weight
      edge = Enum.find(graph.edges, &(&1.source == a.id and &1.target == b.id))
      assert Map.has_key?(edge, :weight)
      assert_in_delta edge.weight, 0.85, 0.001
    end
  end

  describe "version_diff/2" do
    test "diffs v1 against current body with added/removed lines", %{context: ctx} do
      {:ok, page} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "Diffable",
          slug: "diffable",
          page_type: "note",
          body: "line one\nline two\nline three"
        })

      # v1 snapshot is saved on first body change; update twice.
      {:ok, _} = Brain.update_page(page, %{"body" => "line one\nline two changed\nline three"})
      page = Brain.get_page!(page.id)
      {:ok, _} = Brain.update_page(page, %{"body" => "line one\nline two changed\nline four"})
      page = Brain.get_page!(page.id)

      {:ok, diff} = Brain.version_diff(page, 1)

      assert diff.from == 1
      assert diff.to == page.version
      # old body: "line one", "line two", "line three"
      # new body: "line one", "line two changed", "line four"
      # added:   "line two changed", "line four" => 2
      # removed: "line two", "line three" => 2
      # unchanged: "line one" => 1
      assert diff.changes.added == 2
      assert diff.changes.removed == 2
      assert diff.changes.unchanged == 1
    end

    test "returns error for non-existent version", %{context: ctx} do
      {:ok, page} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "NoVer",
          slug: "no-ver",
          page_type: "note",
          body: "x"
        })

      assert {:error, :version_not_found} = Brain.version_diff(page, 99)
    end
  end

  describe "ensure_daily_note/2" do
    test "creates a daily note and is idempotent", %{context: ctx} do
      date = ~D[2026-07-17]

      {:ok, note1} = Brain.ensure_daily_note(ctx.id, date)
      assert note1.slug == "daily-2026-07-17"
      assert note1.page_type == "note"
      assert note1.meta["kind"] == "journal"
      assert note1.meta["date"] == "2026-07-17"
      assert note1.created_by == "system"

      {:ok, note2} = Brain.ensure_daily_note(ctx.id, date)
      assert note2.id == note1.id
    end
  end

  describe "metrics/1" do
    test "returns extended brain-health metrics with all expected keys", %{context: ctx} do
      # Create some pages and relations so the metrics are non-trivial
      {:ok, a} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "Metric A",
          slug: "metric-a",
          page_type: "note",
          body: "content a"
        })

      {:ok, b} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "Metric B",
          slug: "metric-b",
          page_type: "concept",
          body: "content b"
        })

      {:ok, _} =
        Brain.create_relation(%{
          source_id: a.id,
          target_id: b.id,
          relation_type: "related"
        })

      {:ok, _} =
        Brain.create_relation(%{
          source_id: a.id,
          target_id: b.id,
          relation_type: "semantic"
        })

      metrics = Brain.metrics(ctx.id)

      assert Map.has_key?(metrics, :pages_this_week)
      assert Map.has_key?(metrics, :pages_last_week)
      assert Map.has_key?(metrics, :embedding_coverage)
      assert Map.has_key?(metrics, :relations_by_type)
      assert Map.has_key?(metrics, :contested_count)
      assert Map.has_key?(metrics, :agents)

      # Pages created this week (just created)
      assert metrics.pages_this_week >= 2

      # Embedding coverage is a float between 0.0 and 1.0
      assert is_float(metrics.embedding_coverage)
      assert metrics.embedding_coverage >= 0.0
      assert metrics.embedding_coverage <= 1.0

      # Relations by type includes "related" and "semantic"
      assert metrics.relations_by_type["related"] >= 1
      assert metrics.relations_by_type["semantic"] >= 1

      # Contested count is a non-negative integer
      assert is_integer(metrics.contested_count)
      assert metrics.contested_count >= 0

      # Agents map has expected keys
      assert Map.has_key?(metrics.agents, :sessions_this_week)
      assert Map.has_key?(metrics.agents, :tokens_this_week)
      assert Map.has_key?(metrics.agents, :total_sessions)
    end

    test "embedding_coverage is 0.0 when context has no pages" do
      # Use a fresh context with no pages
      {:ok, empty_ctx} = Brain.create_context(%{name: "Empty Metrics", slug: "empty-metrics"})

      metrics = Brain.metrics(empty_ctx.id)
      assert metrics.embedding_coverage == 0.0
      assert metrics.pages_this_week == 0
      assert metrics.relations_by_type == %{}
      assert metrics.contested_count == 0
      assert metrics.agents.sessions_this_week == 0
      assert metrics.agents.tokens_this_week == 0
      assert metrics.agents.total_sessions == 0
    end

    test "agents metrics counts sessions and tokens from agent_sessions", %{context: ctx} do
      # Insert an agent session with tokens_used in meta
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Dran.Repo.insert!(%Dran.Agent.Session{
        context_id: ctx.id,
        agent_type: "ask",
        input: "test query",
        status: "done",
        started_at: now,
        meta: %{"tokens_used" => 1500}
      })

      metrics = Brain.metrics(ctx.id)

      assert metrics.agents.sessions_this_week >= 1
      assert metrics.agents.tokens_this_week >= 1500
      assert metrics.agents.total_sessions >= 1
    end
  end

  describe "edge cases — derive_title ignores embed lines" do
    test "create_page with body containing only ![[embed]] derives Untitled", %{context: ctx} do
      {:ok, target_page} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "File Page",
          slug: "file-page-1",
          page_type: "note"
        })

      {:ok, page} =
        Brain.create_page(%{
          context_id: ctx.id,
          page_type: "note",
          body: "![[file-page-1]]"
        })

      assert page.title == "Untitled"
      assert page.slug == "untitled"

      # The embed itself is still resolved
      rels = Brain.list_relations_for_page(page.id).outbound
      assert Enum.any?(rels, &(&1.relation_type == "embeds" and &1.target_id == target_page.id))
    end

    test "create_page with embed + text uses the text line as title", %{context: ctx} do
      {:ok, page} =
        Brain.create_page(%{
          context_id: ctx.id,
          page_type: "note",
          body: "![[nonexistent]]\nActual Title Here"
        })

      assert page.title == "Actual Title Here"
    end

    test "create_page with body containing only [[wikilink]] derives Untitled", %{context: ctx} do
      {:ok, page} =
        Brain.create_page(%{
          context_id: ctx.id,
          page_type: "note",
          body: "[[Some Link]]"
        })

      assert page.title == "Untitled"
    end
  end

  describe "edge cases — reresolve_embeds with empty body" do
    test "clears all embeds when body becomes empty", %{context: ctx} do
      {:ok, _a} =
        Brain.create_page(%{context_id: ctx.id, title: "A", slug: "ea", page_type: "note"})

      {:ok, _b} =
        Brain.create_page(%{context_id: ctx.id, title: "B", slug: "eb", page_type: "note"})

      {:ok, note} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "N",
          slug: "en",
          page_type: "note",
          body: "![[ea]] ![[eb]]"
        })

      # Verify embeds exist
      embeds =
        Brain.list_relations_for_page(note.id).outbound
        |> Enum.filter(&(&1.relation_type == "embeds"))

      assert length(embeds) == 2

      # Now clear the body
      {:ok, note} = Brain.update_page(note, %{"body" => ""})

      embeds =
        Brain.list_relations_for_page(note.id).outbound
        |> Enum.filter(&(&1.relation_type == "embeds"))

      assert embeds == []
    end

    test "reresolve_embeds directly with empty body", %{context: ctx} do
      {:ok, a} =
        Brain.create_page(%{context_id: ctx.id, title: "A2", slug: "ea2", page_type: "note"})

      {:ok, note} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "N2",
          slug: "en2",
          page_type: "note",
          body: "![[ea2]]"
        })

      # Verify embed exists
      assert Brain.list_relations_for_page(note.id).outbound
             |> Enum.any?(&(&1.relation_type == "embeds" and &1.target_id == a.id))

      # Update body to empty and re-resolve
      {:ok, note} = Brain.update_page(note, %{"body" => ""})
      {created, not_found} = Brain.reresolve_embeds(note)

      assert created == 0
      assert not_found == []

      embeds =
        Brain.list_relations_for_page(note.id).outbound
        |> Enum.filter(&(&1.relation_type == "embeds"))

      assert embeds == []
    end
  end

  describe "edge cases — rename_slug" do
    test "case-only change (My-Page → my-page) works without unique constraint violation", %{
      context: ctx
    } do
      {:ok, page} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "Test",
          slug: "My-Page",
          page_type: "note"
        })

      {:ok, renamed} = Brain.rename_slug(page, "my-page")
      assert renamed.slug == "my-page"
    end

    test "preserves semantic relations (by IDs) when page is relation target", %{context: ctx} do
      {:ok, target} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "Target",
          slug: "target-page",
          page_type: "concept"
        })

      {:ok, source} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "Source",
          slug: "source-page",
          page_type: "concept"
        })

      {:ok, _rel} =
        Brain.create_relation(%{
          source_id: source.id,
          target_id: target.id,
          relation_type: "related",
          weight: 0.9
        })

      # Rename the target
      {:ok, _renamed} = Brain.rename_slug(target, "renamed-target")

      # The relation should still exist (it uses IDs, not slugs)
      rels = Brain.list_relations_for_page(source.id).outbound
      assert Enum.any?(rels, &(&1.relation_type == "related" and &1.target_id == target.id))
    end
  end

  describe "edge cases — Brain.stats" do
    test "returns valid stats for context with 0 pages" do
      {:ok, empty_ctx} = Brain.create_context(%{name: "Empty Context", slug: "empty-ctx"})

      stats = Brain.stats(empty_ctx.id)

      assert stats.total_pages == 0
      assert stats.by_type == %{}
      assert stats.recent == []
      assert stats.todos_by_status == %{}
      assert stats.orphan_count == 0
      assert stats.total_relations == 0
    end
  end

  describe "edge cases — resolve_embeds with non-existent slug" do
    test "returns slug in not_found without creating broken relation", %{context: ctx} do
      {:ok, note} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "Note",
          slug: "note-missing",
          page_type: "note",
          body: "![[does-not-exist]]"
        })

      # resolve_embeds is called during create_page, so the relation should
      # already have been attempted. Let's verify directly.
      {created, not_found} = Brain.resolve_embeds(note)

      assert created == 0
      assert "does-not-exist" in not_found

      # No embeds relation should exist
      embeds =
        Brain.list_relations_for_page(note.id).outbound
        |> Enum.filter(&(&1.relation_type == "embeds"))

      assert embeds == []
    end

    test "mixed existing and non-existent embeds", %{context: ctx} do
      {:ok, target_page} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "Art",
          slug: "art-exists",
          page_type: "note"
        })

      {:ok, note} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "N",
          slug: "n-mixed",
          page_type: "note",
          body: "![[art-exists]] and ![[nope-not-here]]"
        })

      {created, not_found} = Brain.resolve_embeds(note)

      assert created == 1
      assert "nope-not-here" in not_found

      embeds =
        Brain.list_relations_for_page(note.id).outbound
        |> Enum.filter(&(&1.relation_type == "embeds"))

      assert length(embeds) == 1
      assert hd(embeds).target_id == target_page.id
    end
  end
end
