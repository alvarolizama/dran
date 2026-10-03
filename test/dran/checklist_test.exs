defmodule Dran.ChecklistTest do
  @moduledoc """
  Gate W4b (contract.md): el plan es una PÁGINA con campo `:checklist`.

  No existe tabla `plans` ni `checklist_items`; el checklist es un array
  ordenado en el jsonb del contenedor (`[%{"text", "done"}]`) y tachar un
  ítem no crea ni mueve tasks ni toca el board (P13 / Constraint 16 / F35).
  """

  use Dran.DataCase, async: false

  alias Dran.{Accounts, Checklist, Knowledge, Tasks, Workspace}

  setup do
    ws = Dran.DataCase.ensure_workspace!()
    {:ok, ws: ws, owner: member!("owner")}
  end

  test "no existe la tabla plans ni checklist_items" do
    refute table_exists?("plans")
    refute table_exists?("checklist_items")
  end

  test "cast/1 normaliza a [%{text, done}] y preserva el orden" do
    items =
      Checklist.cast([
        %{"text" => "uno", "done" => false},
        %{"text" => "dos", "done" => true},
        "tres"
      ])

    assert items == [
             %{"text" => "uno", "done" => false},
             %{"text" => "dos", "done" => true},
             %{"text" => "tres", "done" => false}
           ]

    # Acepta el JSON serializado y descarta lo que no tiene texto.
    assert Checklist.cast(Jason.encode!(items)) == items
    assert Checklist.cast([%{"text" => "  "}, nil, 42]) == []
    assert Checklist.cast(nil) == []
    assert Checklist.cast("no es json") == []
  end

  test "el plan es una página de tipo declarado con campo :checklist", %{ws: ws} do
    fields = [
      %{
        "slug" => "plan",
        "label" => "Plan",
        "plural" => "Planes",
        "path" => "plans",
        "meta_fields" => [["checklist", "steps", "Steps"]]
      }
    ]

    {:ok, _} =
      ws |> Workspace.settings_changeset(%{workspace_page_types: fields}) |> Repo.update()

    ws = Repo.get!(Workspace, ws.id)

    assert Workspace.page_type_meta_fields(ws, "plan") == [{"checklist", "steps", "Steps"}]
    assert Workspace.page_type_ui(ws, "plan").path == "plans"
  end

  test "tachar un ítem reescribe el jsonb y no crea ni mueve tasks", %{ws: ws, owner: owner} do
    {:ok, page} =
      Knowledge.create_page(%{
        workspace_id: ws.id,
        title: "Plan #{System.unique_integer([:positive])}",
        page_type: "note",
        owner_user_id: owner.id
      })

    tasks_before = Repo.aggregate(Tasks.Task, :count)

    items = Checklist.cast([%{"text" => "Primer paso", "done" => true}])
    {:ok, updated} = Knowledge.update_page(page, %{meta: %{"steps" => items}})

    assert updated.meta["steps"] == [%{"text" => "Primer paso", "done" => true}]

    # El checklist vive en el jsonb del contenedor: cero tasks nuevas.
    assert Repo.aggregate(Tasks.Task, :count) == tasks_before
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp table_exists?(name) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_name = $1",
        [name]
      )

    count == 1
  end

  defp member!(label) do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.create_user(%{
        email: "#{label}-#{unique}@dran.test",
        api_token: "tok-#{label}-#{unique}"
      })

    user
  end
end
