defmodule Dran.TasksSaveEditTest do
  @moduledoc """
  `Tasks.save_edit/3`: el caso de uso ÚNICO de la edición de una task (el modal
  del board y el del detalle del goal). Se prueba en el contexto —sin LiveView—
  porque ahí está la lógica: contenido, pasos y estado, cada uno por su puerta y
  en el orden que respeta el bloqueo optimista.
  """

  use Dran.DataCase, async: false

  alias Dran.{Goals, Tasks}

  setup do
    ws = Dran.DataCase.ensure_workspace!()
    {:ok, goal} = Goals.create_goal(%{"title" => "Meta", "status" => "active"})
    {:ok, task} = Tasks.create_task(%{"goal_id" => goal.id, "title" => "Antes"})

    {:ok, ws: ws, goal: goal, task: task}
  end

  test "guarda contenido, pasos y estado de una sola vez", %{task: task} do
    assert {:ok, updated} =
             Tasks.save_edit(task, %{"title" => "Después", "status" => "done"},
               checklist: ~s([{"id":"s1","text":"Paso","done":false}]),
               lock_version: task.lock_version
             )

    assert updated.title == "Después"
    assert updated.status == "done"
    assert [%{"text" => "Paso"}] = updated.checklist
  end

  test "sin editor de pasos no toca el array", %{task: task} do
    {:ok, with_steps} =
      Tasks.set_checklist(task, ~s([{"id":"s1","text":"Paso","done":false}]),
        lock_version: task.lock_version
      )

    assert {:ok, updated} = Tasks.save_edit(with_steps, %{"title" => "Título nuevo"})
    assert [%{"text" => "Paso"}] = updated.checklist
  end

  test "el cuerpo se guarda con el contenido (y el alta lo acepta)", %{task: task} do
    assert {:ok, updated} =
             Tasks.save_edit(task, %{"title" => "Con cuerpo", "body" => "**Con** markdown"})

    assert updated.body == "**Con** markdown"
    assert Dran.Repo.get!(Tasks.Task, task.id).body == "**Con** markdown"

    # Y el alta: el cuerpo entra por el mismo changeset del contenido.
    assert {:ok, created} =
             Tasks.create_task(%{
               "goal_id" => task.goal_id,
               "title" => "Nueva con cuerpo",
               "body" => "cuerpo de la nueva"
             })

    assert created.body == "cuerpo de la nueva"
  end

  test "un select vacío no invalida la prioridad (normaliza a nil)", %{task: task} do
    {:ok, with_priority} = Tasks.save_edit(task, %{"priority" => "high"})
    assert with_priority.priority == "high"

    assert {:ok, cleared} =
             Tasks.save_edit(with_priority, %{"priority" => "", "due_date" => ""})

    assert cleared.priority == nil
    assert cleared.due_date == nil
  end

  test "el estado sólo se mueve si cambió", %{task: task} do
    {:ok, _same} = Tasks.save_edit(task, %{"title" => "Igual"}, status: task.status)

    # Sin cambio de columna, la posición no se reescribe.
    assert Dran.Repo.get!(Tasks.Task, task.id).position == task.position
  end

  test "un estado forjado no mueve nada", %{task: task} do
    assert {:error, :invalid_status} =
             Tasks.save_edit(task, %{"title" => "Forjado"}, status: "no_existe")

    # El contenido tampoco se escribe a medias: el paso 3 falla sin tocar la fila.
    assert Dran.Repo.get!(Tasks.Task, task.id).title == "Antes"
  end

  test "un lock viejo del formulario se reporta como stale y no escribe nada", %{task: task} do
    # El lock gobierna el RMW de los pasos: con el array ya reescrito por otra
    # mano, el form viejo no puede sobreescribirlo (ni tocar el contenido).
    {:ok, moved} =
      Tasks.set_checklist(task, ~s([{"id":"s1","text":"Paso","done":false}]),
        lock_version: task.lock_version
      )

    assert {:error, :stale} =
             Tasks.save_edit(moved, %{"title" => "Viejo"},
               checklist: "[]",
               lock_version: task.lock_version
             )

    assert Dran.Repo.get!(Tasks.Task, task.id).title == "Antes"
    assert [%{"text" => "Paso"}] = Dran.Repo.get!(Tasks.Task, task.id).checklist
  end
end
