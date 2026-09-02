defmodule DranWeb.TaskLiveTest do
  use DranWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Dran.{Goals, Knowledge, Repo, Tasks}

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

    {:ok, ws} = Knowledge.create_workspace(%{name: "Task Page Test", slug: "task-page-test"})

    {:ok, task} =
      Tasks.create_task(%{
        "workspace_id" => ws.id,
        "title" => "Review PR",
        "body" => "Detailed instructions here"
      })

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user, "test_user")
      |> Plug.Conn.put_session(:workspace_slug, ws.slug)
      |> Plug.Conn.put_session(:is_owner, true)

    {:ok, conn: conn, ws: ws, task: task}
  end

  describe "show" do
    test "renders the task in view mode with title and body", %{conn: conn, ws: ws, task: task} do
      {:ok, _view, html} = live(conn, ~p"/#{ws.slug}/tasks/#{task.id}")

      assert html =~ "Review PR"
      assert html =~ "Detailed instructions here"
      refute html =~ "task-edit-form"
    end

    test "?edit=true renders the edit form with the Tiptap editor", %{
      conn: conn,
      ws: ws,
      task: task
    } do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/tasks/#{task.id}?edit=true")

      assert has_element?(view, "#task-edit-form")
      assert has_element?(view, "#task-editor-#{task.id}[phx-hook='MarkdownEditor']")
    end

    test "renders the assignee and goal badges once set", %{conn: conn, ws: ws, task: task} do
      {:ok, agent} = Dran.Actors.create_actor(%{"name" => "badge-agent", "kind" => "agent"})

      {:ok, goal} =
        Goals.create_goal(%{
          "workspace_id" => ws.id,
          "title" => "Badge goal",
          "slug" => "badge-goal"
        })

      {:ok, _} = Tasks.update_task(task, %{"assignee_actor_id" => agent.id})
      {:ok, _} = Tasks.set_goal(task, goal.id)

      {:ok, _view, html} = live(conn, ~p"/#{ws.slug}/tasks/#{task.id}")

      assert html =~ "badge-agent"
      assert html =~ "Badge goal"
    end

    test "a task from another workspace redirects back to the board", %{conn: conn, ws: ws} do
      {:ok, other} =
        Knowledge.create_workspace(%{
          name: "Other #{System.unique_integer([:positive])}",
          slug: "other-#{System.unique_integer([:positive])}"
        })

      {:ok, foreign} = Tasks.create_task(%{"workspace_id" => other.id, "title" => "Foreign"})

      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, ~p"/#{ws.slug}/tasks/#{foreign.id}")

      assert to == "/#{ws.slug}/tasks"
    end

    test "a non-UUID id redirects to the board instead of crashing", %{conn: conn, ws: ws} do
      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, ~p"/#{ws.slug}/tasks/not-a-uuid")

      assert to == "/#{ws.slug}/tasks"
    end
  end

  describe "edit" do
    test "save updates title and body", %{conn: conn, ws: ws, task: task} do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/tasks/#{task.id}?edit=true")

      view
      |> form("#task-edit-form")
      |> render_submit(%{"task" => %{"title" => "Renamed PR", "body" => "New body text"}})

      updated = Repo.reload!(task)
      assert updated.title == "Renamed PR"
      assert updated.body == "New body text"

      assert_redirect(view, "/#{ws.slug}/tasks/#{task.id}")
    end

    test "save reassigns the actor", %{conn: conn, ws: ws, task: task} do
      {:ok, agent} = Dran.Actors.create_actor(%{"name" => "page-agent", "kind" => "agent"})

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/tasks/#{task.id}?edit=true")

      view
      |> form("#task-edit-form")
      |> render_submit(%{"task" => %{"title" => task.title, "assignee_actor_id" => agent.id}})

      assert Repo.reload!(task).assignee_actor_id == agent.id
    end

    test "save unassigns the actor when the select is empty", %{conn: conn, ws: ws, task: task} do
      {:ok, agent} = Dran.Actors.create_actor(%{"name" => "page-agent-2", "kind" => "agent"})
      {:ok, _} = Tasks.update_task(task, %{"assignee_actor_id" => agent.id})

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/tasks/#{task.id}?edit=true")

      view
      |> form("#task-edit-form")
      |> render_submit(%{"task" => %{"title" => task.title, "assignee_actor_id" => ""}})

      assert Repo.reload!(task).assignee_actor_id == nil
    end

    test "save sets and clears due_date and priority", %{conn: conn, ws: ws, task: task} do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/tasks/#{task.id}?edit=true")

      view
      |> form("#task-edit-form")
      |> render_submit(%{
        "task" => %{"title" => task.title, "due_date" => "2026-12-24", "priority" => "high"}
      })

      updated = Repo.reload!(task)
      assert updated.due_date == ~D[2026-12-24]
      assert updated.priority == "high"

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/tasks/#{task.id}?edit=true")

      view
      |> form("#task-edit-form")
      |> render_submit(%{"task" => %{"title" => task.title, "due_date" => "", "priority" => ""}})

      updated = Repo.reload!(task)
      assert updated.due_date == nil
      assert updated.priority == nil
    end

    test "save with an empty title shows a validation error and keeps the task", %{
      conn: conn,
      ws: ws,
      task: task
    } do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/tasks/#{task.id}?edit=true")

      view
      |> form("#task-edit-form")
      |> render_submit(%{"task" => %{"title" => "", "body" => "x"}})

      assert Repo.reload!(task).title == "Review PR"
      assert has_element?(view, "#task-edit-form")
    end

    test "save links the task to the selected goal", %{conn: conn, ws: ws, task: task} do
      {:ok, goal} =
        Goals.create_goal(%{"workspace_id" => ws.id, "title" => "Linked", "slug" => "linked"})

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/tasks/#{task.id}?edit=true")

      view
      |> form("#task-edit-form")
      |> render_submit(%{"task" => %{"title" => task.title, "goal_id" => goal.id}})

      assert [%{id: linked_goal_id}] = Tasks.list_linked_goals(Tasks.get_task(task.id))
      assert linked_goal_id == goal.id
    end

    test "save detaches the task when the goal select is empty", %{
      conn: conn,
      ws: ws,
      task: task
    } do
      {:ok, goal} =
        Goals.create_goal(%{"workspace_id" => ws.id, "title" => "Gone", "slug" => "gone"})

      {:ok, _} = Tasks.set_goal(task, goal.id)

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/tasks/#{task.id}?edit=true")

      view
      |> form("#task-edit-form")
      |> render_submit(%{"task" => %{"title" => task.title, "goal_id" => ""}})

      assert Tasks.list_linked_goals(Tasks.get_task(task.id)) == []
    end

    test "switching goals moves the link", %{conn: conn, ws: ws, task: task} do
      {:ok, g1} =
        Goals.create_goal(%{"workspace_id" => ws.id, "title" => "G One", "slug" => "g-one"})

      {:ok, g2} =
        Goals.create_goal(%{"workspace_id" => ws.id, "title" => "G Two", "slug" => "g-two"})

      {:ok, _} = Tasks.set_goal(task, g1.id)

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/tasks/#{task.id}?edit=true")

      view
      |> form("#task-edit-form")
      |> render_submit(%{"task" => %{"title" => task.title, "goal_id" => g2.id}})

      task = Tasks.get_task(task.id)
      assert [%{id: g2_id}] = Tasks.list_linked_goals(task)
      assert g2_id == g2.id
    end

    test "the goal select renders flattened options at any depth", %{
      conn: conn,
      ws: ws,
      task: task
    } do
      {:ok, root} =
        Goals.create_goal(%{"workspace_id" => ws.id, "title" => "Root G", "slug" => "root-g"})

      {:ok, child} =
        Goals.create_goal(%{
          "workspace_id" => ws.id,
          "title" => "Child G",
          "slug" => "child-g",
          "parent_goal_id" => root.id
        })

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/tasks/#{task.id}?edit=true")

      assert has_element?(view, "select[name='task[goal_id]'] option[value='#{child.id}']")
      assert has_element?(view, "select[name='task[goal_id]'] option[value='#{root.id}']")
      assert has_element?(view, "select[name='task[goal_id]'] option[value='']")
    end

    test "cancel_edit returns to view mode", %{conn: conn, ws: ws, task: task} do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/tasks/#{task.id}?edit=true")

      render_click(view, "cancel_edit", %{})

      refute has_element?(view, "#task-edit-form")
      assert render(view) =~ "Review PR"
    end

    test "toggle_archive archives the task and navigates back to the board", %{
      conn: conn,
      ws: ws,
      task: task
    } do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/tasks/#{task.id}?edit=true")

      render_click(view, "toggle_archive", %{})

      assert Repo.reload!(task).archived == true
      assert_redirect(view, "/#{ws.slug}/tasks")
    end
  end
end
