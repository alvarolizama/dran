defmodule Dran.TasksMoveTest do
  @moduledoc """
  Gate W4b (contract.md): el move por los DOS ejes.

  Mover una task entre goals es un `UPDATE` atómico que recomputa el progreso
  derivado de AMBOS y respeta `lock_version` (P10 / F37).
  """

  use Dran.DataCase, async: false

  alias Dran.{Accounts, Goals, Tasks}

  setup do
    {:ok, user: member!("mover")}
  end

  test "mover entre goals deja la task en el destino y recomputa los DOS progresos", %{user: user} do
    a = goal!(user, %{"title" => "Goal A"})
    b = goal!(user, %{"title" => "Goal B"})
    {:ok, task} = Tasks.create_task(%{"goal_id" => a.id, "title" => "T"})

    assert Goals.progress(a).total == 1
    assert Goals.progress(b).total == 0

    assert {:ok, moved} = Tasks.move_task(task, %{"goal_id" => b.id, "status" => "todo"})

    assert moved.goal_id == b.id
    assert moved.status == "todo"
    assert moved.lock_version == task.lock_version + 1

    assert Goals.progress(a).total == 0
    assert Goals.progress(b).total == 1
    assert Goals.progress(b).done == 0
  end

  test "un lock_version desfasado devuelve :stale", %{user: user} do
    a = goal!(user)
    b = goal!(user)
    {:ok, task} = Tasks.create_task(%{"goal_id" => a.id, "title" => "T"})

    assert {:ok, moved} = Tasks.move_task(task, %{"goal_id" => b.id, "status" => "todo"})
    assert moved.lock_version == task.lock_version + 1

    # `task` sigue con la versión vieja: un cambio real desde ese estado es
    # obsoleto contra la fila (que ya está en lock_version + 1).
    assert {:error, :stale} =
             Tasks.move_task(task, %{"goal_id" => b.id, "status" => "in_progress"})
  end

  test "mover dentro del goal reordena por posición (gap)", %{user: user} do
    goal = goal!(user)
    {:ok, first} = Tasks.create_task(%{"goal_id" => goal.id, "title" => "Uno"})
    {:ok, second} = Tasks.create_task(%{"goal_id" => goal.id, "title" => "Dos"})

    assert first.position < second.position

    assert {:ok, moved} = Tasks.move_task(second, %{"before_id" => first.id})
    assert moved.position < first.position

    ordered = Enum.map(Tasks.list_tasks(goal_id: goal.id), & &1.id)
    assert ordered == [second.id, first.id]
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp member!(label) do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.create_user(%{
        email: "#{label}-#{unique}@dran.test",
        api_token: "tok-#{label}-#{unique}"
      })

    user
  end

  defp goal!(owner, extra \\ %{}) do
    {:ok, goal} =
      Goals.create_goal(
        Map.merge(%{"title" => "Meta #{uniq()}", "owner_user_id" => owner.id}, extra)
      )

    goal
  end

  defp uniq, do: System.unique_integer([:positive])
end
