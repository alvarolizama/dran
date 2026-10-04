defmodule Dran.ChecklistTest do
  @moduledoc """
  Gate W1 (contract.md): UN checklist, la misma forma para el plan y la task.

  El plan es una ENTIDAD con columna `plans.checklist` (no una página de tipo
  declarado: el fixture que declaraba `plan` como tipo custom se retiró con la
  decisión del owner del 2026-10-03), y la task tiene `tasks.checklist`. Las dos
  comparten forma y cast — `[%{"text" => _, "done" => _}]` ordenado — y tachar un
  ítem reescribe el array: no crea ni mueve tasks ni toca el board.

  No existe `plan_steps` (ni `steps`, ni `checklist_items`): los pasos son un
  array en el jsonb de su contenedor (Constraint 8 / P7).
  """

  use Dran.DataCase, async: false

  alias Dran.{Accounts, Checklist, Goals, Plans, Tasks, Workspace}

  setup do
    ws = Dran.DataCase.ensure_workspace!()
    {:ok, ws: ws, owner: member!("owner")}
  end

  test "no existe tabla de pasos ni de ítems de checklist" do
    refute table_exists?("steps")
    refute table_exists?("plan_steps")
    refute table_exists?("checklist_items")
    # El contenedor del plan SÍ existe y es una tabla propia.
    assert table_exists?("plans")
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

  test "toggle/2 es puro: índice, texto y fuera de rango" do
    items = Checklist.cast(["uno", "dos"])

    assert {:ok, [%{"done" => true}, %{"done" => false}]} = Checklist.toggle(items, 0)
    assert {:ok, [_, %{"text" => "dos", "done" => true}]} = Checklist.toggle(items, "  DOS ")
    assert :error = Checklist.toggle(items, 5)
    assert :error = Checklist.toggle(items, "no está")
    assert :error = Checklist.toggle(items, nil)

    # El orden se conserva y el original no se muta.
    assert items == [%{"text" => "uno", "done" => false}, %{"text" => "dos", "done" => false}]
  end

  test "el plan y la task comparten forma y cast", %{owner: owner} do
    {:ok, plan} =
      Plans.create_plan(%{
        "title" => "Plan #{uniq()}",
        "owner_user_id" => owner.id,
        "checklist" => ["primero", %{"text" => "segundo", "done" => true}]
      })

    {:ok, goal} = Goals.create_goal(%{"title" => "Meta #{uniq()}", "owner_user_id" => owner.id})

    {:ok, task} =
      Tasks.create_task(%{
        "goal_id" => goal.id,
        "title" => "Task #{uniq()}",
        "checklist" => ["primero", %{"text" => "segundo", "done" => true}]
      })

    assert plan.checklist == task.checklist
    assert plan.checklist == Checklist.cast(task.checklist)
  end

  test "tachar un paso del plan no crea ni mueve tasks", %{owner: owner} do
    {:ok, plan} =
      Plans.create_plan(%{
        "title" => "Plan #{uniq()}",
        "owner_user_id" => owner.id,
        "checklist" => [%{"text" => "Primer paso", "done" => false}]
      })

    tasks_before = Repo.aggregate(Tasks.Task, :count)

    {:ok, toggled} = Plans.toggle_checklist(plan, 0)
    assert toggled.checklist == [%{"text" => "Primer paso", "done" => true}]

    # El checklist vive en el jsonb del contenedor: cero tasks nuevas.
    assert Repo.aggregate(Tasks.Task, :count) == tasks_before
    assert Repo.aggregate(Goals.Goal, :count) == 0
  end

  test "`plan` no expone campos de meta porque no es un tipo de página", %{ws: ws} do
    assert Workspace.page_type_meta_fields(ws, "plan") == []
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

  defp uniq, do: System.unique_integer([:positive])
end
