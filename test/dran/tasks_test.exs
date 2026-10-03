defmodule Dran.TasksTest do
  @moduledoc """
  Gate W4b (contract.md): el contenedor de trabajo y su invariante de motor.

  Una task NO puede existir sin goal — lo rechaza el motor (`goal_id NOT
  NULL`), no la app — y el goal bandeja se crea perezosamente en la primera
  captura (P9 / Constraint 11 / F37).
  """

  use Dran.DataCase, async: false

  alias Dran.{Accounts, ContentVisibility, Goals, Tasks}

  setup do
    {:ok, user: member!("owner")}
  end

  test "una task no puede existir sin goal: lo rechaza el MOTOR", %{user: user} do
    # Se saltea el changeset a propósito: el invariante no es de la app.
    assert_raise Postgrex.Error, fn ->
      Repo.insert!(%Dran.Tasks.Task{title: "Huérfana", slug: "huerfana-#{uniq()}"})
    end

    # La puerta normal tampoco lo permite (changeset), pero el motor es la
    # garantía de fondo.
    assert {:error, changeset} =
             Tasks.create_task(%{"title" => "Sin goal", "owner_user_id" => user.id})

    assert %{goal_id: [_ | _]} = errors_on(changeset)
  end

  test "una task con goal existe y aparece en el board de su columna", %{user: user} do
    goal = goal!(user)
    {:ok, task} = Tasks.create_task(%{"goal_id" => goal.id, "title" => "Comprar pan"})

    assert task.goal_id == goal.id
    assert task.status == "backlog"
    assert task.position == 100

    board = Tasks.list_board(goal.id)
    assert Enum.map(board["backlog"], & &1.id) == [task.id]
    assert board["done"] == []
  end

  test "el goal bandeja se crea perezosamente y es idempotente", %{user: user} do
    assert {:ok, inbox} = Goals.ensure_inbox(user.id)
    assert inbox.owner_user_id == user.id
    assert inbox.slug == "inbox"

    assert {:ok, again} = Goals.ensure_inbox(user.id)
    assert again.id == inbox.id
  end

  test "las lecturas del contexto derivan del scope del goal", %{user: user} do
    goal = goal!(user)
    {:ok, task} = Tasks.create_task(%{"goal_id" => goal.id, "title" => "A"})

    scope = ContentVisibility.resolve(nil, user, :goal)
    assert Tasks.get_task(task.id, scope: scope).id == task.id
    assert Tasks.get_task(task.id, scope: {:reader, 999_999}) == nil
  end

  test "el slug de una task es único dentro de su goal", %{user: user} do
    goal = goal!(user)
    {:ok, a} = Tasks.create_task(%{"goal_id" => goal.id, "title" => "Repetida"})
    {:ok, b} = Tasks.create_task(%{"goal_id" => goal.id, "title" => "Repetida"})

    assert a.slug == "repetida"
    assert b.slug != a.slug
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
