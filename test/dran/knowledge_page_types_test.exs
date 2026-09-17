defmodule Dran.KnowledgePageTypesTest do
  @moduledoc """
  W2 — per-workspace custom page types.

  Covers the pre-registered claims:

  - **P4**: `Knowledge.create_page/1` rejects a `page_type` outside the
    workspace's EFFECTIVE types (fail-closed).
  - **P5**: a workspace with `workspace_page_types` resolves its effective
    types = 4 built-in ∪ custom.
  - **P-estructural**: a `workspace_page_types` entry with a duplicated
    `slug` or `path` is rejected at save time.
  """
  use Dran.DataCase, async: false

  alias Dran.Knowledge
  alias Dran.Workspace

  @recipe %{
    "slug" => "recipe",
    "label" => "Receta",
    "plural" => "Recetas",
    "path" => "recipes",
    "icon" => "hero-beaker",
    "color" => "amber",
    "meta_fields" => []
  }

  setup do
    {:ok, ws} = Knowledge.create_workspace(%{name: "Types WS", slug: "types-ws"})
    %{ws: ws}
  end

  defp with_custom(ws, types) when is_list(types) do
    {:ok, updated} = Knowledge.update_workspace_settings(ws, %{workspace_page_types: types})
    updated
  end

  describe "P5 — effective types = 4 built-in ∪ custom" do
    test "a workspace without custom types has exactly the 4 built-in", %{ws: ws} do
      assert Knowledge.page_types(ws) == Dran.Knowledge.Page.all_types()
      assert Knowledge.page_types(ws) == ~w(note entity concept reference)
    end

    test "custom types are appended after the built-ins, in declaration order", %{ws: ws} do
      ws =
        with_custom(ws, [
          @recipe,
          %{@recipe | "slug" => "trip", "path" => "trips", "label" => "Viaje"}
        ])

      assert Knowledge.page_types(ws) == ~w(note entity concept reference recipe trip)
      assert Knowledge.effective_page_types(ws) == ~w(note entity concept reference recipe trip)
    end

    test "page_types/0 stays the built-in list for compatibility", %{ws: _ws} do
      assert Knowledge.page_types() == ~w(note entity concept reference)
    end

    test "enabled_page_types/1 subtracts disabled types from the effective set", %{ws: ws} do
      ws = with_custom(ws, [@recipe])
      {:ok, ws} = Knowledge.update_workspace_settings(ws, %{disabled_page_types: ["recipe"]})

      enabled = Knowledge.enabled_page_types(ws)
      refute "recipe" in enabled
      assert "note" in enabled
      assert length(enabled) == 4
    end

    test "a custom type's declared path/label/icon/color resolve through the workspace", %{ws: ws} do
      ws = with_custom(ws, [@recipe])

      assert Workspace.page_type_path(ws, "recipe") == "recipes"
      assert Workspace.page_type_label(ws, "recipe") == "Receta"
      assert Workspace.page_type_plural(ws, "recipe") == "Recetas"
      assert Workspace.page_type_icon(ws, "recipe") == "hero-beaker"
      assert Workspace.page_type_color(ws, "recipe") == "amber"

      # Built-ins keep their registry presentation.
      assert Workspace.page_type_path(ws, "note") == "notes"
      assert Workspace.page_type_label(ws, "note") == "Note"
    end

    test "page_type_by_path/2 resolves custom paths and unknown paths are nil", %{ws: ws} do
      ws = with_custom(ws, [@recipe])

      assert Workspace.page_type_by_path(ws, "recipes") == "recipe"
      assert Workspace.page_type_by_path(ws, "notes") == "note"
      assert Workspace.page_type_by_path(ws, "nope") == nil
    end
  end

  describe "P4 — create_page/1 and update_page/2 are fail-closed" do
    test "create_page/1 accepts a custom page type of the workspace", %{ws: ws} do
      ws = with_custom(ws, [@recipe])

      assert {:ok, page} =
               Knowledge.create_page(%{
                 "workspace_id" => ws.id,
                 "title" => "Paella",
                 "page_type" => "recipe",
                 "body" => "arroz"
               })

      assert page.page_type == "recipe"
    end

    test "create_page/1 rejects a page type outside the effective types", %{ws: ws} do
      {:error, changeset} =
        Knowledge.create_page(%{
          "workspace_id" => ws.id,
          "title" => "Inventada",
          "page_type" => "plan",
          "body" => "no debería existir"
        })

      assert %{page_type: [_ | _]} = errors_on(changeset)
    end

    test "create_page/1 rejects a custom type declared by ANOTHER workspace", %{ws: ws} do
      {:ok, other} = Knowledge.create_workspace(%{name: "Otro", slug: "otro-ws"})
      with_custom(other, [@recipe])

      {:error, changeset} =
        Knowledge.create_page(%{
          "workspace_id" => ws.id,
          "title" => "Cruzada",
          "page_type" => "recipe",
          "body" => "no es de este workspace"
        })

      assert %{page_type: [_ | _]} = errors_on(changeset)
    end

    test "update_page/2 rejects changing page_type to an unknown type", %{ws: ws} do
      {:ok, page} =
        Knowledge.create_page(%{
          "workspace_id" => ws.id,
          "title" => "Nota",
          "page_type" => "note",
          "body" => "cuerpo"
        })

      {:error, changeset} = Knowledge.update_page(page, %{"page_type" => "bogus"})
      assert %{page_type: [_ | _]} = errors_on(changeset)
    end

    test "update_page/2 accepts a valid effective type change", %{ws: ws} do
      ws = with_custom(ws, [@recipe])

      {:ok, page} =
        Knowledge.create_page(%{
          "workspace_id" => ws.id,
          "title" => "Nota",
          "page_type" => "note",
          "body" => "cuerpo"
        })

      assert {:ok, updated} = Knowledge.update_page(page, %{"page_type" => "recipe"})
      assert updated.page_type == "recipe"
    end

    test "the disabled-type contract still returns :page_type_disabled", %{ws: ws} do
      {:ok, ws} = Knowledge.update_workspace_settings(ws, %{disabled_page_types: ["reference"]})

      assert {:error, :page_type_disabled} =
               Knowledge.create_page(%{
                 "workspace_id" => ws.id,
                 "title" => "Ref",
                 "page_type" => "reference",
                 "body" => "x"
               })
    end
  end

  describe "P-estructural — slug/path uniqueness at save time" do
    test "a duplicated slug is rejected", %{ws: ws} do
      duplicate = %{@recipe | "path" => "other-path"}

      assert {:error, changeset} =
               Knowledge.update_workspace_settings(ws, %{workspace_page_types: [@recipe, duplicate]})

      assert message = custom_type_error(changeset)
      assert message =~ "duplicate slug"
      assert message =~ "recipe"
    end

    test "a duplicated path is rejected", %{ws: ws} do
      same_path = %{@recipe | "slug" => "dish"}

      assert {:error, changeset} =
               Knowledge.update_workspace_settings(ws, %{workspace_page_types: [@recipe, same_path]})

      assert message = custom_type_error(changeset)
      assert message =~ "duplicate path"
      assert message =~ "recipes"
    end

    test "a custom slug colliding with a built-in is rejected", %{ws: ws} do
      collision = %{@recipe | "slug" => "note", "path" => "notes-custom"}

      assert {:error, changeset} =
               Knowledge.update_workspace_settings(ws, %{workspace_page_types: [collision]})

      assert custom_type_error(changeset) =~ "cannot redefine built-in page type"
    end

    test "an entry missing slug or path is rejected", %{ws: ws} do
      assert {:error, changeset} =
               Knowledge.update_workspace_settings(ws, %{
                 workspace_page_types: [Map.delete(@recipe, "slug")]
               })

      assert custom_type_error(changeset) =~ "requires both slug and path"
    end

    test "a valid list saves and round-trips through the DB", %{ws: ws} do
      ws = with_custom(ws, [@recipe])

      reloaded = Knowledge.get_workspace!(ws.id)
      assert [entry] = Workspace.custom_page_types(reloaded)
      assert entry["slug"] == "recipe"
      assert entry["path"] == "recipes"
      assert entry["label"] == "Receta"
    end
  end

  describe "disabled_page_types validates against effective types" do
    test "disabling a custom type is accepted (not a subset error)", %{ws: ws} do
      ws = with_custom(ws, [@recipe])

      assert {:ok, ws} =
               Knowledge.update_workspace_settings(ws, %{disabled_page_types: ["recipe"]})

      assert "recipe" in (ws.disabled_page_types || [])
    end

    test "an unknown disabled type is still rejected", %{ws: ws} do
      assert {:error, changeset} =
               Knowledge.update_workspace_settings(ws, %{disabled_page_types: ["bogus_type"]})

      assert %{disabled_page_types: [_ | _]} = errors_on(changeset)
    end
  end

  describe "teardown of a custom type" do
    test "removing a custom type leaves the built-ins untouched", %{ws: ws} do
      ws = with_custom(ws, [@recipe])
      {:ok, ws} = Knowledge.update_workspace_settings(ws, %{workspace_page_types: []})

      assert Knowledge.page_types(ws) == ~w(note entity concept reference)
    end
  end

  defp custom_type_error(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> Map.get(:workspace_page_types, [])
    |> List.first()
  end
end
