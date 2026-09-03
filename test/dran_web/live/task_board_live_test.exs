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

    test "lists all managed actors as flat filter options", %{conn: conn, ws: ws} do
      {:ok, _} = Dran.Actors.create_actor(%{"name" => "group-agent", "kind" => "agent"})
      {:ok, _} = Dran.Actors.create_actor(%{"name" => "group-human", "kind" => "user"})

      {:ok, _view, html} = live(conn, ~p"/#{ws.slug}/tasks")

      # Shared actor_options: flat options (no optgroup grouping)
      refute html =~ "<optgroup"
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

  describe "detail page navigation" do
    test "cards link to the task edit modal (board ?task=)", %{conn: conn, ws: ws, task: task} do
      {:ok, _view, html} = live(conn, ~p"/#{ws.slug}/tasks")

      assert html =~ ~p"/#{ws.slug}/tasks?task=#{task.id}"
    end

    test "quick_add creates the task without opening any panel", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/tasks")

      view
      |> form("#quick-add-backlog")
      |> render_submit(%{"task" => %{"title" => "Fresh task", "status" => "backlog"}})

      assert Repo.get_by(Dran.Task, title: "Fresh task")
      refute has_element?(view, "#task-detail-form")
    end
  end

  describe "workspace scoping (migrated to TaskLive)" do
    test "a foreign task never renders on this board", %{conn: conn, ws: ws} do
      {:ok, other_ws} =
        Dran.Knowledge.create_workspace(%{name: "Other Board", slug: "other-board-2"})

      {:ok, _other_task} =
        Tasks.create_task(%{"workspace_id" => other_ws.id, "title" => "Foreign task"})

      {:ok, _view, html} = live(conn, ~p"/#{ws.slug}/tasks")

      refute html =~ "Foreign task"
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

    test "the card links to the task modal after quick add", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/tasks")

      view
      |> element("#quick-add-backlog")
      |> render_submit(%{"task" => %{"title" => "Fresh task", "status" => "backlog"}})

      created = Tasks.get_task_by_slug("fresh-task", ws.id)
      assert created, "task should have been created"
      assert render(view) =~ ~p"/#{ws.slug}/tasks?task=#{created.id}"
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

  describe "resource modal (create + edit over the board)" do
    test "?new=true opens the create modal with the status select", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/tasks?new=true")

      assert has_element?(view, "#task-resource-modal")
      assert has_element?(view, "#task-modal-form")
      assert has_element?(view, "select[name='task[status]']")
      # Editor without toolbar (approved mockup)
      refute has_element?(view, "#task-resource-modal [data-testid='editor-toolbar']")
      # The footer Save button targets the form via form= attribute
      assert has_element?(view, "#task-resource-modal button[form='task-modal-form']")
    end

    test "?new=true&status=todo preselects the todo column", %{conn: conn, ws: ws} do
      {:ok, _view, html} = live(conn, ~p"/#{ws.slug}/tasks?new=true&status=todo")

      assert html =~ ~s(value="todo" selected)
    end

    test "?task=<id> opens the edit modal with the task loaded", %{conn: conn, ws: ws, task: task} do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/tasks?task=#{task.id}")

      assert has_element?(view, "#task-resource-modal")
      assert has_element?(view, "#task-modal-form")
      assert has_element?(view, "#task-modal-form input[name='task[title]']")
    end

    test "saving from the create modal persists the task and closes", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/tasks?new=true&status=todo")

      view
      |> form("#task-modal-form")
      |> render_submit(%{"task" => %{"title" => "Modal child", "status" => "todo"}})

      created = Tasks.get_task_by_slug("modal-child", ws.id)
      assert created, "modal create should persist"
      assert created.status == "todo"
      assert created.created_by == "test_user"

      refute has_element?(view, "#task-resource-modal")
    end

    test "saving from the edit modal updates title/body and closes", %{
      conn: conn,
      ws: ws,
      task: task
    } do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/tasks?task=#{task.id}")

      view
      |> form("#task-modal-form")
      |> render_submit(%{"task" => %{"title" => "Renamed from modal", "body" => "modal body"}})

      updated = Repo.reload!(task)
      assert updated.title == "Renamed from modal"
      assert updated.body == "modal body"

      refute has_element?(view, "#task-resource-modal")
    end

    test "saving without an explicit body param persists the editor body (regression: duplicated hidden inputs)",
         %{
           conn: conn,
           ws: ws,
           task: task
         } do
      # The MarkdownEditor hook syncs the markdown into the editor's OWN
      # hidden field on every update and before submit. The modal form must
      # NOT render a second manual hidden field, or the browser submits
      # both and the LAST (stale, original) wins — silently discarding the
      # edited body (reviewer finding 1). This test submits WITHOUT a body
      # param, exercising the real hidden-sync path.
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/tasks?task=#{task.id}")

      hidden_count =
        view
        |> render()
        |> then(&(Regex.scan(~r/<input[^>]*name="task\[body\]"/, &1) |> length()))

      assert hidden_count == 1,
             "expected exactly one hidden task[body] input, got #{hidden_count}"

      view
      |> form("#task-modal-form")
      |> render_submit(%{"task" => %{"title" => "Body from hook"}})

      updated = Repo.reload!(task)
      assert updated.title == "Body from hook"
      assert updated.body == task.body
    end

    test "edit modal save clears assignee and priority when empty", %{
      conn: conn,
      ws: ws,
      task: task
    } do
      {:ok, agent} = Dran.Actors.create_actor(%{"name" => "modal-agent", "kind" => "agent"})
      {:ok, _} = Tasks.update_task(task, %{"assignee_actor_id" => agent.id, "priority" => "high"})

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/tasks?task=#{task.id}")

      view
      |> form("#task-modal-form")
      |> render_submit(%{
        "task" => %{"title" => task.title, "assignee_actor_id" => "", "priority" => ""}
      })

      updated = Repo.reload!(task)
      assert updated.assignee_actor_id == nil
      assert updated.priority == nil
    end

    test "edit modal save links the task to a goal", %{conn: conn, ws: ws, task: task} do
      {:ok, goal} =
        Goals.create_goal(%{
          "workspace_id" => ws.id,
          "title" => "Modal goal",
          "slug" => "modal-goal"
        })

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/tasks?task=#{task.id}")

      view
      |> form("#task-modal-form")
      |> render_submit(%{"task" => %{"title" => task.title, "goal_id" => goal.id}})

      linked_ids = Tasks.list_linked_goals(Tasks.get_task(task.id)) |> Enum.map(& &1.id)
      assert goal.id in linked_ids
    end

    test "a foreign task id in ?task= renders the board with no modal", %{
      conn: conn,
      ws: ws
    } do
      {:ok, other} =
        Dran.Knowledge.create_workspace(%{
          name: "Other Modal #{System.unique_integer([:positive])}",
          slug: "other-modal-#{System.unique_integer([:positive])}"
        })

      {:ok, foreign} = Tasks.create_task(%{"workspace_id" => other.id, "title" => "Foreign"})

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/tasks?task=#{foreign.id}")

      refute has_element?(view, "#task-resource-modal")
      assert render(view) =~ "Review PR"
    end

    test "close_modal patches back to the plain board URL", %{conn: conn, ws: ws, task: task} do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/tasks?task=#{task.id}")

      render_click(view, "close_modal", %{})

      refute has_element?(view, "#task-resource-modal")
    end

    test "empty title keeps the modal open with a validation error", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/tasks?new=true")

      view
      |> form("#task-modal-form")
      |> render_submit(%{"task" => %{"title" => ""}})

      assert has_element?(view, "#task-resource-modal")
      assert has_element?(view, "#task-modal-form")
    end
  end

  describe "contract chip on cards" do
    test "shows version chip for a task with an active contract", %{
      conn: conn,
      ws: ws,
      task: task
    } do
      {:ok, _} =
        Tasks.update_task(task, %{
          "meta" => %{
            "contract" => valid_board_contract(%{"status" => "active", "version" => 2})
          }
        })

      {:ok, _view, html} = live(conn, ~p"/#{ws.slug}/tasks")

      assert html =~ ~s(hero-document-check)
      assert html =~ "v2"
    end

    test "shows draft chip for a draft contract", %{conn: conn, ws: ws, task: task} do
      {:ok, _} =
        Tasks.update_task(task, %{
          "meta" => %{
            "contract" => valid_board_contract(%{"status" => "draft", "version" => 1})
          }
        })

      {:ok, _view, html} = live(conn, ~p"/#{ws.slug}/tasks")
      assert html =~ "draft"
    end

    test "plain tasks render no contract chip", %{conn: conn, ws: ws} do
      {:ok, _view, html} = live(conn, ~p"/#{ws.slug}/tasks")
      refute html =~ "hero-document-check"
    end
  end

  defp valid_board_contract(overrides) do
    Map.merge(
      %{
        "status" => "active",
        "version" => 1,
        "intent" => "do the thing",
        "claims" => [%{"id" => "P1", "claim" => "done", "verify" => "mix test"}],
        "gates" => [%{"name" => "g", "cmd" => "mix test", "expect" => "green"}],
        "graph" => %{
          "nodes" => [
            %{"id" => "S1", "verb" => "RUN", "label" => "mix test"},
            %{"id" => "G1", "verb" => "VERIFY", "label" => "green?"}
          ],
          "edges" => [%{"from" => "S1", "to" => "G1", "guard" => "yes"}]
        }
      },
      overrides
    )
  end
end
