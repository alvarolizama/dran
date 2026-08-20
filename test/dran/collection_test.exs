defmodule Dran.CollectionTest do
  use Dran.DataCase, async: false

  alias Dran.Knowledge

  alias Dran.Collections

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
      Knowledge.get_workspace_by_slug("personal") ||
        elem(Knowledge.create_workspace(%{name: "Personal", slug: "personal"}), 1)

    {:ok, context: context}
  end

  describe "create_collection/1" do
    test "creates a collection with valid attrs", %{context: ctx} do
      attrs = %{
        workspace_id: ctx.id,
        name: "Test Collection",
        slug: "test-collection"
      }

      assert {:ok, %Dran.Collection{} = collection} = Collections.create_collection(attrs)
      assert collection.name == "Test Collection"
    end
  end

  describe "list_collections/1" do
    test "lists collections in a workspace", %{context: ctx} do
      {:ok, _} =
        Collections.create_collection(%{
          workspace_id: ctx.id,
          name: "Collection A",
          slug: "collection-a"
        })

      {:ok, _} =
        Collections.create_collection(%{
          workspace_id: ctx.id,
          name: "Collection B",
          slug: "collection-b"
        })

      collections = Collections.list_collections(ctx.id)
      assert length(collections) == 2
    end
  end
end
