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
end
