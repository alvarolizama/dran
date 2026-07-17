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
  end

  describe "embeds auto-resolution" do
    test "create_page resolves ![[embed]] into embeds relation", %{context: ctx} do
      {:ok, artifact} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "File",
          slug: "file-a",
          page_type: "artifact"
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

      assert Enum.any?(rels, &(&1.relation_type == "embeds" and &1.target_id == artifact.id))
    end

    test "update_page removes stale embeds relations", %{context: ctx} do
      {:ok, a} =
        Brain.create_page(%{context_id: ctx.id, title: "A", slug: "a", page_type: "artifact"})

      {:ok, b} =
        Brain.create_page(%{context_id: ctx.id, title: "B", slug: "b", page_type: "artifact"})

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
          page_type: "artifact"
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
          page_type: "artifact"
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
end
