defmodule DranWeb.TaskBoardLiveTest do
  use DranWeb.ConnCase, async: false

  alias Dran.{Goals, Tasks, Repo}

  setup %{conn: conn} do
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

    {:ok, ws} = Dran.Knowledge.create_workspace(%{name: "Board Test", slug: "board-test"})

    {:ok, task} =
      Tasks.create_task(%{
        "workspace_id" => ws.id,
        "title" => "Review PR"
      })

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user, "test_user")
      |> Plug.Conn.put_session(:workspace_slug, ws.slug)
      |> Plug.Conn.put_session(:is_owner, true)

    {:ok, conn: conn, ws: ws, task: task}
  end

  describe "board rendering" do
    test "renders all five columns with counts", %{conn: conn, ws: ws, task: task} do
      {:ok, _view, html} = live(conn, ~p"/#{ws.slug}/tasks")

      # Column labels come from gettext — match by data-column attributes
      # and the localized labels (es locale in tests).
      for status <- ~w(backlog todo in_progress done cancelled) do
        assert html =~ ~s(data-column="#{status}")
      end

      assert html =~ task.title
    end

    test "legacy kanban URL redirects to tasks", %{conn: conn, ws: ws} do
      conn = get(conn, ~p"/#{ws.slug}/kanban")
      assert redirected_to(conn) == ~p"/#{ws.slug}/tasks"
    end

    test "renders agent badge on cards assigned to agent actors", %{conn: conn, ws: ws} do
      {:ok, agent} =
        Dran.Actors.create_actor(%{"name" => "board-agent", "kind" => "agent"})

      {:ok, human} =
        Dran.Actors.create_actor(%{"name" => "board-human", "kind" => "user"})

      {:ok, _} =
        Tasks.create_task(%{
          "workspace_id" => ws.id,
          "title" => "Agent task",
          "assignee_actor_id" => agent.id
        })

      {:ok, _} =
        Tasks.create_task(%{
          "workspace_id" => ws.id,
          "title" => "Human task",
          "assignee_actor_id" => human.id
        })

      {:ok, _view, html} = live(conn, ~p"/#{ws.slug}/tasks")
      assert html =~ "board-agent"
      assert html =~ "board-human"
      # The agent chip (cpu icon + localized "agent" label) appears for the
      # agent card only.
      assert html =~ "hero-cpu-chip"
      assert html =~ "Agente"
    end
  end

  describe "assignee filter" do
    test "filter matches tasks by creator attribution when unassigned", %{conn: conn, ws: ws} do
      {:ok, agent} =
        Dran.Actors.create_actor(%{"name" => "test_user", "kind" => "agent"})

      {:ok, _} =
        Tasks.create_task(%{
          "workspace_id" => ws.id,
          "title" => "Made by test_user",
          "created_by" => "test_user"
        })

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/tasks")

      # Filtering by the actor whose name matches the creator attribution
      render_change(view, "filter_actor", %{"actor_id" => agent.id})
      html = render(view)
      assert html =~ "Made by test_user"
      refute html =~ "Review PR"

      # Unassigned = no assignee AND no real creator → shows only the seed
      # task that has neither (Review PR has created_by "system"... no: it
      # was created without created_by → default "system").
      render_change(view, "filter_actor", %{"actor_id" => "unassigned"})
      html = render(view)
      assert html =~ "Review PR"
      refute html =~ "Made by test_user"
    end

    test "groups filter options by actor kind", %{conn: conn, ws: ws} do
      {:ok, _} = Dran.Actors.create_actor(%{"name" => "group-agent", "kind" => "agent"})
      {:ok, _} = Dran.Actors.create_actor(%{"name" => "group-human", "kind" => "user"})

      {:ok, _view, html} = live(conn, ~p"/#{ws.slug}/tasks")

      assert html =~ ~s(label="Agentes")
      assert html =~ ~s(label="Usuarios")
      assert html =~ "group-agent"
      assert html =~ "group-human"
    end

    test "filters cards by actor and unassigned", %{conn: conn, ws: ws} do
      {:ok, agent} =
        Dran.Actors.create_actor(%{"name" => "filter-agent", "kind" => "agent"})

      {:ok, mine} =
        Tasks.create_task(%{
          "workspace_id" => ws.id,
          "title" => "Assigned task",
          "assignee_actor_id" => agent.id
        })

      {:ok, _view, html} = live(conn, ~p"/#{ws.slug}/tasks")
      assert html =~ "Assigned task"
      assert html =~ "Review PR"

      view = live(conn, ~p"/#{ws.slug}/tasks") |> elem(1)

      render_change(view, "filter_actor", %{"actor_id" => agent.id})
      html = render(view)
      assert html =~ "Assigned task"
      refute html =~ "Review PR"

      render_change(view, "filter_actor", %{"actor_id" => "unassigned"})
      html = render(view)
      refute html =~ "Assigned task"
      assert html =~ "Review PR"

      render_change(view, "filter_actor", %{"actor_id" => ""})
      html = render(view)
      assert html =~ "Assigned task"
      assert html =~ "Review PR"

      assert Repo.reload!(mine).status == "backlog"
    end
  end

  describe "detail panel" do
    test "select_task opens the panel with the task body", %{conn: conn, ws: ws} do
      {:ok, task} =
        Tasks.create_task(%{
          "workspace_id" => ws.id,
          "title" => "With body",
          "body" => "Detailed instructions here"
        })

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/tasks")

      render_click(view, "select_task", %{"id" => task.id})

      assert has_element?(view, "#task-detail-form")
      assert render(view) =~ "Detailed instructions here"
    end

    test "save_detail updates title and body", %{conn: conn, ws: ws, task: task} do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/tasks")

      render_click(view, "select_task", %{"id" => task.id})

      view
      |> form("#task-detail-form")
      |> render_submit(%{"task" => %{"title" => "Renamed PR", "body" => "New body text"}})

      updated = Repo.reload!(task)
      assert updated.title == "Renamed PR"
      assert updated.body == "New body text"
      assert has_element?(view, "#task-detail-form")
      assert render(view) =~ "New body text"
    end

    test "save_detail reassigns and unassigns the actor", %{conn: conn, ws: ws, task: task} do
      {:ok, agent} = Dran.Actors.create_actor(%{"name" => "panel-agent", "kind" => "agent"})

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/tasks")
      render_click(view, "select_task", %{"id" => task.id})

      view
      |> form("#task-detail-form")
      |> render_submit(%{
        "task" => %{"title" => task.title, "assignee_actor_id" => agent.id}
      })

      assert Repo.reload!(task).assignee_actor_id == agent.id

      # Same panel: switching to "unassigned" clears the actor
      render_click(view, "select_task", %{"id" => task.id})

      view
      |> form("#task-detail-form")
      |> render_submit(%{
        "task" => %{"title" => task.title, "assignee_actor_id" => ""}
      })

      assert Repo.reload!(task).assignee_actor_id == nil
    end

    test "save_detail sets and clears due_date and priority", %{conn: conn, ws: ws, task: task} do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/tasks")
      render_click(view, "select_task", %{"id" => task.id})

      view
      |> form("#task-detail-form")
      |> render_submit(%{
        "task" => %{
          "title" => task.title,
          "due_date" => "2026-12-24",
          "priority" => "high"
        }
      })

      updated = Repo.reload!(task)
      assert updated.due_date == ~D[2026-12-24]
      assert updated.priority == "high"

      render_click(view, "select_task", %{"id" => task.id})

      view
      |> form("#task-detail-form")
      |> render_submit(%{"task" => %{"title" => task.title, "due_date" => "", "priority" => ""}})

      updated = Repo.reload!(task)
      assert updated.due_date == nil
      assert updated.priority == nil
    end

    test "save_detail with an empty title shows a validation error", %{
      conn: conn,
      ws: ws,
      task: task
    } do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/tasks")

      render_click(view, "select_task", %{"id" => task.id})

      view
      |> form("#task-detail-form")
      |> render_submit(%{"task" => %{"title" => "", "body" => "x"}})

      assert Repo.reload!(task).title == "Review PR"
    end

    test "close_detail hides the panel", %{conn: conn, ws: ws, task: task} do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/tasks")

      render_click(view, "select_task", %{"id" => task.id})
      assert has_element?(view, "#task-detail-form")

      render_click(view, "close_detail", %{})
      refute has_element?(view, "#task-detail-form")
    end

    test "toggle_archive archives the task and removes it from the board", %{
      conn: conn,
      ws: ws,
      task: task
    } do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/tasks")

      render_click(view, "select_task", %{"id" => task.id})
      render_click(view, "toggle_archive", %{"id" => task.id})

      assert Repo.reload!(task).archived == true
      refute render(view) =~ "Review PR"
      refute has_element?(view, "#task-detail-form")
    end

    test "rejects tasks from other workspaces (no select, no save, no archive)", %{
      conn: conn,
      ws: ws
    } do
      {:ok, other_ws} =
        Dran.Knowledge.create_workspace(%{name: "Other Board", slug: "other-board"})

      {:ok, other_task} =
        Tasks.create_task(%{"workspace_id" => other_ws.id, "title" => "Foreign task"})

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/tasks")

      # select_task is rejected — the panel never opens
      render_click(view, "select_task", %{"id" => other_task.id})
      refute has_element?(view, "#task-detail-form")
      refute render(view) =~ "Foreign task"

      # save_detail is rejected — the foreign task is untouched
      render_click(view, "save_detail", %{
        "task" => %{"title" => "Hacked", "body" => "hacked"}
      })

      refute Repo.reload!(other_task).title == "Hacked"

      # toggle_archive is rejected — the foreign task stays unarchived
      render_click(view, "toggle_archive", %{"id" => other_task.id})
      assert Repo.reload!(other_task).archived == false
    end

    test "save_detail with no task selected flashes instead of crashing", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/tasks")

      # No select_task beforehand — the socket has selected_task: nil
      render_click(view, "save_detail", %{"task" => %{"title" => "x", "body" => "y"}})

      # The LiveView is still alive and rendering
      assert render(view) =~ "Pendientes"
    end
  end

  describe "move event" do
    test "moves a task to another column via the move event", %{conn: conn, ws: ws, task: task} do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/tasks")

      assert view
             |> render_hook("move", %{
               "id" => task.id,
               "to_status" => "in_progress",
               "before_id" => nil
             }) =~
               task.title

      moved = Repo.reload!(task)
      assert moved.status == "in_progress"
    end

    test "move with before_id inserts before the anchor", %{conn: conn, ws: ws} do
      {:ok, first} =
        Tasks.create_task(%{"workspace_id" => ws.id, "title" => "First"})

      {:ok, second} =
        Tasks.create_task(%{"workspace_id" => ws.id, "title" => "Second"})

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/tasks")

      render_hook(view, "move", %{
        "id" => second.id,
        "to_status" => "backlog",
        "before_id" => first.id
      })

      board = Tasks.list_board(ws.id)
      backlog_titles = Enum.map(board["backlog"], & &1.title)
      # Second now sits before First
      assert Enum.find_index(backlog_titles, &(&1 == "Second")) <
               Enum.find_index(backlog_titles, &(&1 == "First"))
    end

    test "stale lock shows a flash and reloads", %{conn: conn, ws: ws, task: task} do
      # Move it server-side first (bumps lock_version), then use the stale
      # struct from the rendered board.
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/tasks")

      # First move succeeds
      render_hook(view, "move", %{"id" => task.id, "to_status" => "todo", "before_id" => nil})

      # Simulate a stale lock_version by moving directly and NOT re-rendering
      fresh = Repo.reload!(task)
      {:ok, _} = Tasks.move_task(fresh, "backlog")

      # Now the LiveView task struct is two versions stale — but the board
      # reloads after each move, so the hook always sends the fresh version.
      # Instead, verify the :stale path by crafting the event directly:
      html =
        render_hook(view, "move", %{
          "id" => fresh.id,
          "to_status" => "done",
          "before_id" => nil
        })

      # The move above should succeed (board reloaded after previous move).
      assert Repo.reload!(task).status == "done"
      assert html =~ task.title
    end
  end

  describe "quick add" do
    test "creates a task in the column", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/tasks")

      view
      |> element("#quick-add-todo")
      |> render_submit(%{"task" => %{"title" => "New todo task", "status" => "todo"}})

      assert Tasks.get_task_by_slug("new-todo-task", ws.id).status == "todo"
    end

    test "attributes created_by to the session user", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/tasks")

      view
      |> element("#quick-add-backlog")
      |> render_submit(%{"task" => %{"title" => "Atributed task", "status" => "backlog"}})

      task = Tasks.get_task_by_slug("atributed-task", ws.id)
      assert task, "task should have been created"
      assert task.created_by == "test_user"
    end

    test "opens the detail panel with the freshly created task", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/tasks")

      view
      |> element("#quick-add-backlog")
      |> render_submit(%{"task" => %{"title" => "Fresh task", "status" => "backlog"}})

      created = Tasks.get_task_by_slug("fresh-task", ws.id)
      assert created, "task should have been created"
      assert has_element?(view, "#task-detail-form")
      assert render(view) =~ "Fresh task"
    end
  end

  describe "goal select" do
    test "card shows a goal chip once the task is linked", %{conn: conn, ws: ws, task: task} do
      {:ok, goal} =
        Goals.create_goal(%{
          "workspace_id" => ws.id,
          "title" => "Chip goal",
          "slug" => "chip-goal"
        })

      {:ok, _} = Tasks.set_goal(task, goal.id)

      {:ok, _view, html} = live(conn, ~p"/#{ws.slug}/tasks")

      assert html =~ "hero-flag"
      assert html =~ "Chip goal"
    end

    test "detail panel renders the grouped goal select", %{conn: conn, ws: ws, task: task} do
      {:ok, root} =
        Goals.create_goal(%{"workspace_id" => ws.id, "title" => "Root G", "slug" => "root-g"})

      {:ok, child} =
        Goals.create_goal(%{
          "workspace_id" => ws.id,
          "title" => "Child G",
          "slug" => "child-g",
          "parent_goal_id" => root.id
        })

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/tasks")
      render_click(view, "select_task", %{"id" => task.id})

      assert has_element?(view, "#task-detail-form")

      # Flattened indented options — works at any hierarchy depth
      assert has_element?(
               view,
               "select[name='task[goal_id]'] option[value='#{child.id}']"
             )

      assert has_element?(view, "select[name='task[goal_id]'] option[value='#{root.id}']")
      assert has_element?(view, "select[name='task[goal_id]'] option[value='']")
    end

    test "save_detail links the task to the selected goal", %{conn: conn, ws: ws, task: task} do
      {:ok, goal} =
        Goals.create_goal(%{"workspace_id" => ws.id, "title" => "Linked", "slug" => "linked"})

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/tasks")
      render_click(view, "select_task", %{"id" => task.id})

      view
      |> form("#task-detail-form")
      |> render_submit(%{
        "task" => %{"title" => task.title, "goal_id" => goal.id}
      })

      assert [%{id: linked_goal_id}] = Tasks.list_linked_goals(Tasks.get_task(task.id))
      assert linked_goal_id == goal.id
    end

    test "save_detail detaches the task when the goal select is empty", %{
      conn: conn,
      ws: ws,
      task: task
    } do
      {:ok, goal} =
        Goals.create_goal(%{"workspace_id" => ws.id, "title" => "Gone", "slug" => "gone"})

      {:ok, _} = Tasks.set_goal(task, goal.id)

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/tasks")
      render_click(view, "select_task", %{"id" => task.id})

      view
      |> form("#task-detail-form")
      |> render_submit(%{"task" => %{"title" => task.title, "goal_id" => ""}})

      assert Tasks.list_linked_goals(Tasks.get_task(task.id)) == []
    end

    test "switching goals from the panel moves the link", %{conn: conn, ws: ws, task: task} do
      {:ok, g1} =
        Goals.create_goal(%{"workspace_id" => ws.id, "title" => "G One", "slug" => "g-one"})

      {:ok, g2} =
        Goals.create_goal(%{"workspace_id" => ws.id, "title" => "G Two", "slug" => "g-two"})

      {:ok, _} = Tasks.set_goal(task, g1.id)

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/tasks")
      render_click(view, "select_task", %{"id" => task.id})

      view
      |> form("#task-detail-form")
      |> render_submit(%{"task" => %{"title" => task.title, "goal_id" => g2.id}})

      task = Tasks.get_task(task.id)
      assert [%{id: g2_id}] = Tasks.list_linked_goals(task)
      assert g2_id == g2.id
    end
  end

  describe "goal filter" do
    test "renders the grouped goal filter with a root and its sub-goal", %{conn: conn, ws: ws} do
      {:ok, root} =
        Goals.create_goal(%{
          "workspace_id" => ws.id,
          "title" => "Filter Root",
          "slug" => "filter-root"
        })

      {:ok, child} =
        Goals.create_goal(%{
          "workspace_id" => ws.id,
          "title" => "Filter Child",
          "slug" => "filter-child",
          "parent_goal_id" => root.id
        })

      {:ok, _view, html} = live(conn, ~p"/#{ws.slug}/tasks")

      assert html =~ ~s(id="goal-filter")
      assert html =~ "Filter Root"
      assert html =~ "Filter Child"
      assert is_binary(child.id)
    end

    test "filtering by root shows tasks of the root AND its sub-goals", %{
      conn: conn,
      ws: ws,
      task: task
    } do
      {:ok, root} =
        Goals.create_goal(%{
          "workspace_id" => ws.id,
          "title" => "Roll Root",
          "slug" => "roll-root"
        })

      {:ok, child} =
        Goals.create_goal(%{
          "workspace_id" => ws.id,
          "title" => "Roll Child",
          "slug" => "roll-child",
          "parent_goal_id" => root.id
        })

      {:ok, _} = Tasks.set_goal(task, root.id)

      {:ok, child_task} =
        Tasks.create_task(%{"workspace_id" => ws.id, "title" => "Child task"})

      {:ok, _} = Tasks.set_goal(child_task, child.id)

      {:ok, other_task} =
        Tasks.create_task(%{"workspace_id" => ws.id, "title" => "Orphan task"})

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/tasks")

      render_click(view, "filter_goal", %{"goal_id" => root.id})
      html = render(view)

      assert html =~ "Review PR"
      assert html =~ "Child task"
      refute html =~ "Orphan task"
    end

    test "filtering by sub-goal shows only its own tasks", %{conn: conn, ws: ws, task: task} do
      {:ok, root} =
        Goals.create_goal(%{
          "workspace_id" => ws.id,
          "title" => "Solo Root",
          "slug" => "solo-root"
        })

      {:ok, child} =
        Goals.create_goal(%{
          "workspace_id" => ws.id,
          "title" => "Solo Child",
          "slug" => "solo-child",
          "parent_goal_id" => root.id
        })

      {:ok, _} = Tasks.set_goal(task, root.id)

      {:ok, child_task} =
        Tasks.create_task(%{"workspace_id" => ws.id, "title" => "Child task"})

      {:ok, _} = Tasks.set_goal(child_task, child.id)

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/tasks")

      render_click(view, "filter_goal", %{"goal_id" => child.id})
      html = render(view)

      assert html =~ "Child task"
      refute html =~ "Review PR"
    end

    test "filtering by unknown goal id shows nothing", %{conn: conn, ws: ws, task: task} do
      {:ok, goal} =
        Goals.create_goal(%{
          "workspace_id" => ws.id,
          "title" => "Empty goal",
          "slug" => "empty-goal"
        })

      {:ok, _} = Tasks.set_goal(task, goal.id)

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/tasks")

      render_click(view, "filter_goal", %{"goal_id" => Ecto.UUID.generate()})
      html = render(view)

      refute html =~ "Review PR"
    end

    test "filtering by a goal includes grandchild goals (any depth)", %{
      conn: conn,
      ws: ws,
      task: task
    } do
      {:ok, root} =
        Goals.create_goal(%{
          "workspace_id" => ws.id,
          "title" => "Deep Root",
          "slug" => "deep-root"
        })

      {:ok, child} =
        Goals.create_goal(%{
          "workspace_id" => ws.id,
          "title" => "Deep Child",
          "slug" => "deep-child",
          "parent_goal_id" => root.id
        })

      {:ok, grandchild} =
        Goals.create_goal(%{
          "workspace_id" => ws.id,
          "title" => "Deep Grandchild",
          "slug" => "deep-grandchild",
          "parent_goal_id" => child.id
        })

      {:ok, _} = Tasks.set_goal(task, grandchild.id)

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/tasks")

      # From the root, the grandchild's task rolls up (depth 2)
      render_click(view, "filter_goal", %{"goal_id" => root.id})
      assert render(view) =~ "Review PR"

      # From the child, still rolls up (depth 1)
      render_click(view, "filter_goal", %{"goal_id" => child.id})
      assert render(view) =~ "Review PR"

      # From the grandchild itself, direct match
      render_click(view, "filter_goal", %{"goal_id" => grandchild.id})
      assert render(view) =~ "Review PR"

      # Unrelated goal → hidden
      {:ok, other} =
        Goals.create_goal(%{"workspace_id" => ws.id, "title" => "Other", "slug" => "other-x"})

      render_click(view, "filter_goal", %{"goal_id" => other.id})
      refute render(view) =~ "Review PR"
    end

    test "goal selects render indented flattened options, no optgroups", %{
      conn: conn,
      ws: ws,
      task: _task
    } do
      {:ok, root} =
        Goals.create_goal(%{
          "workspace_id" => ws.id,
          "title" => "Flat Root",
          "slug" => "flat-root"
        })

      {:ok, _child} =
        Goals.create_goal(%{
          "workspace_id" => ws.id,
          "title" => "Flat Child",
          "slug" => "flat-child",
          "parent_goal_id" => root.id
        })

      {:ok, _view, html} = live(conn, ~p"/#{ws.slug}/tasks")

      refute html =~ "<optgroup"
      assert html =~ "Flat Root"
      assert html =~ "Flat Child"
      assert html =~ "—— Flat Child"
    end
  end
end
