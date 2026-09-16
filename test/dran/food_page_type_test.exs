defmodule Dran.FoodPageTypeTest do
  @moduledoc """
  Cobertura del tipo de página `food` — registry, meta fields y changeset.
  Sigue el patrón de `Dran.KnowledgeTest` (workspace "personal" + inference off).
  """
  use Dran.DataCase, async: false

  alias Dran.Knowledge
  alias Dran.PageRegistry

  setup do
    # Disable inference so create_page doesn't call external APIs
    original = Application.get_env(:dran, :inference)

    Application.put_env(:dran, :inference,
      base_url: nil,
      api_key: nil,
      embedding_model: nil,
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

  describe "registry" do
    test "food está en la lista canónica de tipos" do
      assert "food" in PageRegistry.types()
    end

    test "kinds de food" do
      assert PageRegistry.kinds("food") ==
               ~w(recipe ingredient dish meal cuisine restaurant drink technique)
    end

    test "ui attrs de food" do
      assert PageRegistry.ui("food") == %{
               path: "food",
               label: "Food",
               icon: "hero-cake",
               color: "#FB923C",
               plural: "Food"
             }

      assert PageRegistry.path("food") == "food"
      assert PageRegistry.type_from_path("food") == "food"
    end

    test "capabilities de food" do
      assert PageRegistry.graph?("food")
      assert PageRegistry.journey?("food")
      assert PageRegistry.embeddings?("food")
      assert PageRegistry.agent_create?("food")
    end

    test "color de food en el mapa del grafo" do
      assert PageRegistry.type_color("food") == "#FB923C"
      assert {"food", "#FB923C"} in PageRegistry.ordered_type_colors()
    end

    test "agent_description incluye food" do
      assert PageRegistry.agent_description() =~ "food"
    end
  end

  describe "meta fields" do
    test "food expone kind, cuisine, servings, tiempos y source_url" do
      keys =
        Enum.map(PageRegistry.meta_fields("food"), fn
          {_t, key, _l} -> key
          {_t, key, _l, _o} -> key
        end)

      assert keys == [
               "kind",
               "cuisine",
               "servings",
               "prep_time",
               "cook_time",
               "source_url",
               "props"
             ]
    end
  end

  describe "changeset" do
    test "acepta un kind válido y persiste meta de food", %{context: ctx} do
      assert {:ok, page} =
               Knowledge.create_page(%{
                 "title" => "Mole poblano",
                 "body" => "Receta tradicional",
                 "page_type" => "food",
                 "workspace_id" => ctx.id,
                 "meta" => %{"kind" => "recipe", "cuisine" => "mexican", "servings" => "6"}
               })

      assert page.page_type == "food"
      assert page.meta["kind"] == "recipe"
      assert page.meta["cuisine"] == "mexican"
    end

    test "PageMeta.changeset valida los kinds de food", %{context: _ctx} do
      alias Dran.Knowledge.PageMeta

      valid =
        PageMeta.changeset(%PageMeta{}, %{"kind" => "recipe", "cuisine" => "mexican"}, "food")

      assert valid.valid?
      assert Ecto.Changeset.get_change(valid, :kind) == "recipe"
      assert Ecto.Changeset.get_change(valid, :cuisine) == "mexican"

      invalid = PageMeta.changeset(%PageMeta{}, %{"kind" => "alien"}, "food")
      refute invalid.valid?
      assert %{kind: [_ | _]} = errors_on(invalid)
    end
  end
end
