defmodule Dran.IntegrationTest do
  @moduledoc """
  End-to-end integration test covering the full happy-path pipeline:

    create → embed → rename → search → export

  Inference is disabled entirely (base_url: nil) so no embedding calls
  are attempted. The Brain functions degrade gracefully — embeddings
  stay nil, but FTS search and all other operations work normally.
  """
  use Dran.DataCase, async: false

  alias Dran.Knowledge
  alias Dran.Exporter

  setup do
    original = Application.get_env(:dran, :inference)

    # Disable inference entirely (base_url: nil → enabled?() returns false).
    # This means:
    # - Embeddings.schedule/1 returns :ignored immediately (no API calls)
    # - PageAugmenter.schedule/1 returns :ignored immediately
    # - Embeddings stay nil on all pages
    # - Knowledge.search/1 falls back to :fuzzy_fts or :fts strategy (graceful degradation)
    # - FTS search works perfectly without embeddings
    Application.put_env(:dran, :inference,
      base_url: nil,
      api_key: nil,
      embedding_model: nil,
      rerank_model: nil,
      chat_model: nil,
      timeout: 50,
      schedule_async: false,
      use_rerank: false
    )

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:dran, :inference)
      else
        Application.put_env(:dran, :inference, original)
      end
    end)

    # Create a fresh context for this test
    {:ok, context} =
      Knowledge.create_workspace(%{
        name: "Integration Test",
        slug: "integration-test-#{System.unique_integer()}"
      })

    {:ok, context: context}
  end

  describe "full pipeline: create → embed → rename → search → export" do
    test "create pages, resolve embeds, rename, search, and export", %{context: ctx} do
      # ── 1. Create a note page ──
      {:ok, note_page} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Design Document",
          slug: "design-doc",
          page_type: "note",
          body: "This is the content of the design document."
        })

      assert note_page.slug == "design-doc"
      assert note_page.page_type == "note"

      # ── 2. Create a note that embeds the page via ![[design-doc]] ──
      {:ok, note} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Project Notes",
          slug: "project-notes",
          page_type: "note",
          body: "Here are my notes referencing the design.\n\n![[design-doc]]"
        })

      # ── 3. Assert embeds relation exists ──
      rels = Knowledge.list_relations_for_page(note.id)
      embed_rels = Enum.filter(rels.outbound, &(&1.relation_type == "embeds"))

      assert length(embed_rels) == 1
      embed_rel = hd(embed_rels)
      assert embed_rel.target_id == note_page.id

      # The preloaded target page should have slug but no body (lightweight select)
      assert embed_rel.target.slug == "design-doc"
      assert embed_rel.target.page_type == "note"
      assert embed_rel.target.body == nil or embed_rel.target.body == ""

      # ── 4. Verify embeddings degrade gracefully ──
      # create_page calls Embeddings.schedule which runs synchronously (schedule_async: false).
      # Inference is disabled (base_url: nil), so no embedding call is made
      # and the page's embedding stays nil.
      page_after = Knowledge.get_page!(note_page.id)
      assert page_after.embedding == nil

      note_after = Knowledge.get_page!(note.id)
      assert note_after.embedding == nil

      # ── 5. Rename the page's slug ──
      {:ok, renamed} = Knowledge.rename_slug(note_page, "design-spec")

      assert renamed.slug == "design-spec"

      # The note's body should be updated to reference the new slug
      updated_note = Knowledge.get_page!(note.id)
      assert updated_note.body =~ "![[design-spec]]"
      refute updated_note.body =~ "![[design-doc]]"

      # The embeds relation should still point to the same page (by id)
      rels_after = Knowledge.list_relations_for_page(note.id)
      embed_rels_after = Enum.filter(rels_after.outbound, &(&1.relation_type == "embeds"))
      assert length(embed_rels_after) == 1
      assert hd(embed_rels_after).target_id == note_page.id
      assert hd(embed_rels_after).target.slug == "design-spec"

      # ── 6. Search for the renamed page by content (FTS, no embeddings needed) ──
      {:ok, results} = Knowledge.search("design document", workspace_id: ctx.id)

      # The renamed page should be findable via full-text search
      found = Enum.find(results, &(&1.slug == "design-spec"))
      assert found != nil
      assert found.title == "Design Document"

      # Also search for the note's content
      {:ok, note_results} = Knowledge.search("project notes", workspace_id: ctx.id)
      found_note = Enum.find(note_results, &(&1.slug == "project-notes"))
      assert found_note != nil

      # ── 7. Export the context ──
      {:ok, export} = Exporter.full_export(ctx.id)

      assert export.workspace.id == ctx.id
      assert export.workspace.name == "Integration Test"

      # Export should include both pages
      exported_slugs = Enum.map(export.pages, & &1.slug)
      assert "design-spec" in exported_slugs
      assert "project-notes" in exported_slugs

      # Export should include the embeds relation
      embed_in_export =
        Enum.find(export.relations, fn r ->
          r.relation_type == "embeds" and
            r.source_slug == "project-notes" and
            r.target_slug == "design-spec"
        end)

      assert embed_in_export != nil

      # ── 8. Verify stats work with the optimized group_by queries ──
      stats = Knowledge.stats(ctx.id)

      assert stats.total_pages == 2
      assert stats.by_type["note"] == 2
      assert stats.total_relations >= 1
      assert stats.orphan_count >= 0
    end

    test "stats with todos groups by kanban_status via SQL", %{context: ctx} do
      # Create todo-notes with different kanban statuses
      {:ok, _todo1} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Task A",
          slug: "task-a",
          page_type: "note",
          body: "Do thing A",
          meta: %{"kind" => "todo"},
          kanban_status: "doing"
        })

      {:ok, _todo2} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Task B",
          slug: "task-b",
          page_type: "note",
          body: "Do thing B",
          meta: %{"kind" => "todo"},
          kanban_status: "done"
        })

      {:ok, _todo3} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Task C",
          slug: "task-c",
          page_type: "note",
          body: "Do thing C",
          meta: %{"kind" => "todo"},
          kanban_status: "backlog"
        })

      {:ok, _todo4} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Task D",
          slug: "task-d",
          page_type: "note",
          body: "Do thing D",
          meta: %{"kind" => "todo"}
          # no kanban_status → should default to "backlog"
        })

      stats = Knowledge.stats(ctx.id)

      assert stats.total_pages == 4
      assert stats.by_type["note"] == 4
      assert stats.todos_by_status["doing"] == 1
      assert stats.todos_by_status["done"] == 1
      assert stats.todos_by_status["backlog"] == 2
    end

    test "orphan_pages finds pages with no inbound relations", %{context: ctx} do
      {:ok, a} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Page A",
          slug: "page-a",
          page_type: "note",
          body: "Content A"
        })

      {:ok, b} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Page B",
          slug: "page-b",
          page_type: "note",
          body: "Content B"
        })

      # Create a relation: A → B (B has an inbound relation, A does not)
      {:ok, _rel} =
        Knowledge.create_relation(%{
          source_id: a.id,
          target_id: b.id,
          relation_type: "related"
        })

      orphans = Knowledge.orphan_pages(ctx.id)
      orphan_slugs = Enum.map(orphans, & &1.slug)

      # A has no inbound relations → orphan
      assert "page-a" in orphan_slugs
      # B has an inbound relation → not an orphan
      refute "page-b" in orphan_slugs
    end
  end
end
