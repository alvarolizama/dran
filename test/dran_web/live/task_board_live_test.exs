defmodule DranWeb.TaskBoardLiveTest do
  @moduledoc """
  Gate W4c (P15): el board global filtra por goal y SOLO muestra goals que el
  lector puede leer; el board de un goal ajeno privado no se abre (navega
  fuera). Mover una task desde la UI cambia de columna y el progreso derivado
  del goal se refleja — nunca se guarda.

  El detalle del goal muestra el progreso derivado y sus subgoals legibles.
  """
  use DranWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Dran.{Accounts, Goals, Tasks}

  defp editor!(label) do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.create_user(%{
        email: "#{label}-#{unique}@dran.test",
        api_token: "tok-#{label}-#{unique}"
      })

    user
  end

  # Un lector no-owner: `instance_role` default "editor" se resuelve como
  # `{:reader, id}` — el lector personal ordinario.
  defp login(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:user, user.email)
    |> Plug.Conn.put_session(:is_owner, false)
    |> Plug.Conn.put_session(:workspace_slug, "personal")
  end

  defp goal!(owner, attrs) do
    {:ok, goal} =
      Goals.create_goal(
        Map.merge(
          %{"title" => "Goal #{System.unique_integer([:positive])}", "owner_user_id" => owner.id},
          attrs
        )
      )

    goal
  end

  test "el board global solo muestra las tasks de goals que el lector puede leer" do
    author = editor!("author")
    stranger = editor!("stranger")

    mine = goal!(author, %{"title" => "Mi meta"})
    {:ok, mine_task} = Tasks.create_task(%{"goal_id" => mine.id, "title" => "Visible"})

    theirs = goal!(stranger, %{"title" => "Meta ajena"})
    {:ok, their_task} = Tasks.create_task(%{"goal_id" => theirs.id, "title" => "Secreta"})

    {:ok, view, _html} = live(login(build_conn(), author), ~p"/tasks")

    assert has_element?(view, "#task-card-#{mine_task.id}")
    refute has_element?(view, "#task-card-#{their_task.id}")

    # El filtro por goal solo ofrece lo legible.
    assert has_element?(view, "#board-goal-filter-select option[value='#{mine.id}']")
    refute has_element?(view, "#board-goal-filter-select option[value='#{theirs.id}']")
  end

  test "el board de un goal ajeno privado no se abre: navega fuera" do
    author = editor!("author2")
    stranger = editor!("stranger2")

    theirs = goal!(stranger, %{"title" => "Privada ajena"})

    assert {:error, {:live_redirect, %{to: "/tasks"}}} =
             live(login(build_conn(), author), ~p"/tasks/#{theirs.id}")
  end

  test "el board de un goal propio se abre y muestra sus tasks" do
    author = editor!("author3")
    goal = goal!(author, %{"title" => "Mi board"})
    {:ok, task} = Tasks.create_task(%{"goal_id" => goal.id, "title" => "En mi board"})

    {:ok, view, html} = live(login(build_conn(), author), ~p"/tasks/#{goal.id}")

    assert html =~ "Mi board"
    assert has_element?(view, "#task-card-#{task.id}")
    assert has_element?(view, "#board-all-tasks")
  end

  test "mover una task desde la UI cambia de columna y el progreso derivado se refleja" do
    author = editor!("author4")
    goal = goal!(author, %{"title" => "Con progreso"})
    {:ok, task} = Tasks.create_task(%{"goal_id" => goal.id, "title" => "Mover"})

    {:ok, view, _html} = live(login(build_conn(), author), ~p"/tasks")

    assert has_element?(view, "#column-backlog #task-card-#{task.id}")
    refute has_element?(view, "#column-done #task-card-#{task.id}")

    view
    |> form("#task-move-#{task.id}", %{"status" => "done"})
    |> render_change()

    assert has_element?(view, "#column-done #task-card-#{task.id}")
    refute has_element?(view, "#column-backlog #task-card-#{task.id}")

    # El progreso es DERIVADO de las tasks: mover a done lo refleja.
    assert Goals.progress(goal).done == 1
    assert Goals.progress(goal).total == 1

    # Y el detalle del goal lo muestra.
    {:ok, goal_view, _ghtml} = live(login(build_conn(), author), ~p"/goals/#{goal.id}")
    assert has_element?(goal_view, "#goal-progress[data-done='1'][data-total='1']")
  end

  test "el detalle del goal lista sus subgoals legibles" do
    author = editor!("author5")
    parent = goal!(author, %{"title" => "Padre"})
    child = goal!(author, %{"title" => "Hijo", "parent_goal_id" => parent.id})

    {:ok, view, _html} = live(login(build_conn(), author), ~p"/goals/#{parent.id}")

    assert has_element?(view, "#goal-child-#{child.id}")
  end
end
