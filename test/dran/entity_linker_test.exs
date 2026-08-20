defmodule Dran.EntityLinkerTest do
  use Dran.DataCase, async: false

  alias Dran.Knowledge
  alias Dran.EntityLinker

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

  defp fresh_context(prefix) do
    slug = "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
    {:ok, ctx} = Knowledge.create_workspace(%{name: "Linker Test #{slug}", slug: slug})
    ctx
  end

  defp create_note(ctx, slug) do
    {:ok, page} =
      Knowledge.create_page(%{
        workspace_id: ctx.id,
        title: slug,
        slug: slug,
        page_type: "note",
        body: "Some body"
      })

    page
  end

  describe "normalize_entities/1" do
    test "slugifies, trims, drops empties and dedupes" do
      assert EntityLinker.normalize_entities([
               "Elixir Programming",
               "  elixir programming  ",
               "Dran App",
               "",
               42
             ]) == ["elixir-programming", "dran-app", "42"]
    end

    test "handles empty list" do
      assert EntityLinker.normalize_entities([]) == []
    end
  end

  describe "reject_noise?/1" do
    test "rejects file extension patterns" do
      assert EntityLinker.reject_noise?("readme-md")
      assert EntityLinker.reject_noise?("settings-live-ex")
      assert EntityLinker.reject_noise?("graph-3d-js")
      assert EntityLinker.reject_noise?("page-components-ex")
      assert EntityLinker.reject_noise?("app-eex")
    end

    test "rejects generic tech slugs" do
      assert EntityLinker.reject_noise?("ai")
      assert EntityLinker.reject_noise?("llm")
      assert EntityLinker.reject_noise?("mcp")
      assert EntityLinker.reject_noise?("socket")
      assert EntityLinker.reject_noise?("pubsub")
      assert EntityLinker.reject_noise?("liveview")
      assert EntityLinker.reject_noise?("kanban")
    end

    test "allows real entities" do
      refute EntityLinker.reject_noise?("jacobo-grinberg")
      refute EntityLinker.reject_noise?("phoenix-framework")
      refute EntityLinker.reject_noise?("anthropic")
      refute EntityLinker.reject_noise?("dran")
      refute EntityLinker.reject_noise?("el-claro")
    end
  end

  describe "link/2" do
    test "creates entity pages and mentions relations" do
      ctx = fresh_context("link")
      note = create_note(ctx, "my-note")

      assert {:ok, 2} = EntityLinker.link(note, ["Elixir", "Phoenix Framework"])

      entity = Knowledge.get_page_by_slug("elixir", ctx.id)
      assert entity.page_type == "entity"
      assert entity.meta["auto"] == true

      relations = Knowledge.list_relations_for_page(note.id).outbound
      mentions = Enum.filter(relations, &(&1.relation_type == "mentions"))
      assert length(mentions) == 2
      target_ids = Enum.map(mentions, & &1.target_id)
      assert entity.id in target_ids
    end

    test "reuses existing entity pages instead of duplicating them" do
      ctx = fresh_context("link-reuse")
      note_a = create_note(ctx, "note-a")
      note_b = create_note(ctx, "note-b")

      assert {:ok, 1} = EntityLinker.link(note_a, ["Elixir"])
      assert {:ok, 1} = EntityLinker.link(note_b, ["Elixir"])

      # Only ONE entity page exists
      entities =
        Knowledge.list_pages(workspace_id: ctx.id, type: "entity")
        |> Enum.filter(&(&1.slug == "elixir"))

      assert length(entities) == 1
    end

    test "is idempotent — re-linking the same page creates no new relations" do
      ctx = fresh_context("link-idem")
      note = create_note(ctx, "my-note")

      assert {:ok, 1} = EntityLinker.link(note, ["Elixir"])
      assert {:ok, 1} = EntityLinker.link(note, ["Elixir"])

      relations = Knowledge.list_relations_for_page(note.id).outbound
      mentions = Enum.filter(relations, &(&1.relation_type == "mentions"))
      # create_relation uses on_conflict: :nothing, so at most 1 row exists
      assert length(mentions) == 1
    end

    test "skips entities whose slug collides with a non-entity page" do
      ctx = fresh_context("link-collision")
      _note = create_note(ctx, "elixir")
      other = create_note(ctx, "other-note")

      assert {:ok, 0} = EntityLinker.link(other, ["Elixir"])

      # No entity page created, no relation created
      assert Knowledge.get_page_by_slug("elixir", ctx.id).page_type == "note"
      relations = Knowledge.list_relations_for_page(other.id).outbound
      assert Enum.filter(relations, &(&1.relation_type == "mentions")) == []
    end

    test "skips self-links" do
      ctx = fresh_context("link-self")

      {:ok, entity} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Elixir",
          slug: "elixir",
          page_type: "entity",
          body: ""
        })

      assert {:ok, 0} = EntityLinker.link(entity, ["Elixir"])
    end

    test "caps entities per page at 10" do
      ctx = fresh_context("link-cap")
      note = create_note(ctx, "busy-note")

      entities = for i <- 1..15, do: "Entity Number #{i}"
      assert {:ok, count} = EntityLinker.link(note, entities)
      assert count == 10
    end

    test "page without context links nothing" do
      page = %Dran.Page{workspace_id: nil}
      assert {:ok, 0} = EntityLinker.link(page, ["Elixir"])
    end
  end
end
