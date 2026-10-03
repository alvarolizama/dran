defmodule Dran.TaskVisibilityTest do
  @moduledoc """
  Gate W4b (contract.md): la task HEREDA la visibilidad del goal.

  Las tasks no declaran su propia visibilidad: una task en un goal ajeno
  privado no se lee por ninguna superficie, y moverla a un goal público la
  vuelve legible (P11 / Constraint 12 / F2).
  """

  use Dran.DataCase, async: false

  alias Dran.{Accounts, ContentVisibility, Goals, Tasks}

  test "una task en un goal ajeno privado no se lee" do
    author = member!("author")
    reader = member!("reader")

    goal = goal!(author)
    {:ok, task} = Tasks.create_task(%{"goal_id" => goal.id, "title" => "Secreta"})

    author_scope = ContentVisibility.resolve(nil, author, :goal)
    reader_scope = ContentVisibility.resolve(nil, reader, :goal)

    assert Tasks.get_task(task.id, scope: author_scope).id == task.id

    assert Tasks.get_task(task.id, scope: reader_scope) == nil
    assert Tasks.list_tasks(scope: reader_scope) == []
    assert Tasks.list_tasks_for_goal(goal, scope: reader_scope) == []
  end

  test "si el goal es público, el tercero sí la lee" do
    author = member!("author-pub")
    reader = member!("reader-pub")

    goal = goal!(author, %{"visibility" => "public"})
    {:ok, task} = Tasks.create_task(%{"goal_id" => goal.id, "title" => "Visible"})

    reader_scope = ContentVisibility.resolve(nil, reader, :goal)

    assert Tasks.get_task(task.id, scope: reader_scope).id == task.id
    assert Enum.map(Tasks.list_tasks(scope: reader_scope), & &1.id) == [task.id]
  end

  test "mover la task a un goal público la vuelve legible (hereda del destino)" do
    author = member!("author-move")
    reader = member!("reader-move")

    priv = goal!(author)
    pub = goal!(author, %{"visibility" => "public"})
    {:ok, task} = Tasks.create_task(%{"goal_id" => priv.id, "title" => "Migrante"})

    reader_scope = ContentVisibility.resolve(nil, reader, :goal)
    assert Tasks.get_task(task.id, scope: reader_scope) == nil

    assert {:ok, moved} = Tasks.move_task(task, %{"goal_id" => pub.id})
    assert moved.goal_id == pub.id
    assert Tasks.get_task(task.id, scope: reader_scope).id == task.id
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
