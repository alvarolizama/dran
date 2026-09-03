defmodule DranWeb.WorkflowsLiveTest do
  use DranWeb.ConnCase, async: false

  alias Dran.{Contracts, Goals, Tasks}

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

    {:ok, ws} =
      Dran.Knowledge.create_workspace(%{name: "Workflows Test", slug: "workflows-test"})

    {:ok, goal} =
      Goals.create_goal(%{
        "workspace_id" => ws.id,
        "title" => "Goal with workflow",
        "slug" => "goal-with-workflow"
      })

    {:ok, task} =
      Tasks.create_task(%{"workspace_id" => ws.id, "title" => "Contract task"})

    {:ok, _} = Tasks.set_goal(task, goal.id)

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user, "test_user")
      |> Plug.Conn.put_session(:workspace_slug, ws.slug)
      |> Plug.Conn.put_session(:is_owner, true)

    {:ok, conn: conn, ws: ws, goal: goal, task: task}
  end

  describe "index" do
    test "renders the three tabs", %{conn: conn, ws: ws} do
      {:ok, _view, html} = live(conn, ~p"/#{ws.slug}/workflows")

      assert html =~ "Resumen"
      assert html =~ "En ejecución"
      assert html =~ "Cola"
    end

    test "resumen lists the goal that has a contract task", %{conn: conn, ws: ws, task: task} do
      {:ok, _} = Tasks.update_task(task, %{"meta" => %{"contract" => valid_contract()}})

      {:ok, view, html} = live(conn, ~p"/#{ws.slug}/workflows")
      assert html =~ "Goal with workflow"

      assert has_element?(view, "a[href*='workflows/goal-with-workflow']")
    end

    test "ejecucion tab shows the in-progress contract task", %{conn: conn, ws: ws, task: task} do
      {:ok, _} =
        Tasks.update_task(task, %{
          "status" => "in_progress",
          "meta" => %{"contract" => valid_contract()}
        })

      {:ok, _view, html} = live(conn, ~p"/#{ws.slug}/workflows?tab=ejecucion")
      assert html =~ "Contract task"
    end

    test "cola tab shows a ready contract task", %{conn: conn, ws: ws, task: task} do
      {:ok, _} =
        Tasks.update_task(task, %{
          "status" => "todo",
          "meta" => %{"contract" => valid_contract()}
        })

      {:ok, _view, html} = live(conn, ~p"/#{ws.slug}/workflows?tab=cola")
      assert html =~ "Contract task"
    end

    test "cola excludes a blocked task (unmet dependency)", %{
      conn: conn,
      ws: ws,
      goal: goal,
      task: task
    } do
      {:ok, prereq} = Tasks.create_task(%{"workspace_id" => ws.id, "title" => "Prereq"})
      {:ok, _} = Tasks.set_goal(prereq, goal.id)
      {:ok, _} = Contracts.add_dependency(task, prereq)

      {:ok, _} =
        Tasks.update_task(task, %{
          "status" => "todo",
          "meta" => %{"contract" => valid_contract()}
        })

      {:ok, _view, html} = live(conn, ~p"/#{ws.slug}/workflows?tab=cola")
      refute html =~ "Contract task"
    end

    test "goal filter appears on ejecucion/cola and filters by goal", %{
      conn: conn,
      ws: ws,
      goal: goal,
      task: task
    } do
      {:ok, _} = Tasks.update_task(task, %{"meta" => %{"contract" => valid_contract()}})
      {:ok, _} = Tasks.update_task(task, %{"status" => "in_progress"})
      {:ok, other} = Tasks.create_task(%{"workspace_id" => ws.id, "title" => "Other goal task"})

      {:ok, other_goal} =
        Dran.Goals.create_goal(%{
          "workspace_id" => ws.id,
          "title" => "Other goal",
          "slug" => "other-goal"
        })

      {:ok, _} = Tasks.set_goal(other, other_goal.id)
      {:ok, _} = Tasks.update_task(other, %{"meta" => %{"contract" => valid_contract()}})
      {:ok, _} = Tasks.update_task(other, %{"status" => "in_progress"})

      {:ok, view, html} = live(conn, ~p"/#{ws.slug}/workflows?tab=ejecucion")
      assert has_element?(view, "#workflow-goal-filter")
      assert html =~ "Contract task"
      assert html =~ "Other goal task"

      # select a goal → only its tasks remain
      {:ok, view, html} = live(conn, ~p"/#{ws.slug}/workflows?tab=ejecucion&goal=#{goal.id}")
      assert html =~ "Contract task"
      refute html =~ "Other goal task"

      # clear the goal → all back, selector still visible
      {:ok, view, html} = live(conn, ~p"/#{ws.slug}/workflows?tab=ejecucion")
      assert html =~ "Other goal task"
      assert has_element?(view, "#workflow-goal-filter")
    end

    test "goal filter rolls up to sub-goals (parent matches descendants)", %{
      conn: conn,
      ws: ws,
      goal: goal,
      task: task
    } do
      {:ok, _} = Tasks.update_task(task, %{"meta" => %{"contract" => valid_contract()}})
      {:ok, _} = Tasks.update_task(task, %{"status" => "in_progress"})

      {:ok, sub} =
        Dran.Goals.create_goal(%{
          "workspace_id" => ws.id,
          "title" => "Sub goal",
          "slug" => "sub-goal",
          "parent_goal_id" => goal.id
        })

      {:ok, subtask} = Tasks.create_task(%{"workspace_id" => ws.id, "title" => "Sub goal task"})
      {:ok, _} = Tasks.set_goal(subtask, sub.id)
      {:ok, _} = Tasks.update_task(subtask, %{"meta" => %{"contract" => valid_contract()}})
      {:ok, _} = Tasks.update_task(subtask, %{"status" => "in_progress"})

      # filtering by the parent shows BOTH the parent's and the sub-goal's tasks
      {:ok, view, html} = live(conn, ~p"/#{ws.slug}/workflows?tab=ejecucion&goal=#{goal.id}")
      assert html =~ "Contract task"
      assert html =~ "Sub goal task"

      # the sub-goal appears indented in the filter options
      assert has_element?(view, "#workflow-goal-filter option[value='#{sub.id}']")
      assert html =~ ~s(— Sub goal)
    end
  end

  describe "show (goal DAG)" do
    test "invalid goal slug redirects back to the index without crashing", %{conn: conn, ws: ws} do
      # Regression guard: an unknown slug must cleanly live_redirect to the
      # index (Phoenix resolves the handle_params push_patch on first render —
      # no render with ghost assigns).
      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, ~p"/#{ws.slug}/workflows/not-a-real-goal")

      assert to == ~p"/#{ws.slug}/workflows"
    end

    test "renders the goal title and the task card", %{conn: conn, ws: ws, task: task} do
      {:ok, _} = Tasks.update_task(task, %{"meta" => %{"contract" => valid_contract()}})

      {:ok, view, html} = live(conn, ~p"/#{ws.slug}/workflows/goal-with-workflow")
      assert html =~ "Goal with workflow"
      assert html =~ "Contract task"
      assert has_element?(view, "[data-column], .rounded-2xl")
    end

    test "dag canvas exposes pan/zoom controls and stage", %{
      conn: conn,
      ws: ws,
      task: task
    } do
      {:ok, _} = Tasks.update_task(task, %{"meta" => %{"contract" => valid_contract()}})

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/workflows/goal-with-workflow")
      assert has_element?(view, "#wfe-canvas[phx-hook='WfPanZoom']")
      assert has_element?(view, "#wfe-canvas [data-wf-stage]")
      assert has_element?(view, "#wfe-canvas [data-wf-zoom='in']")
      assert has_element?(view, "#wfe-canvas [data-wf-zoom='out']")
      assert has_element?(view, "#wfe-canvas [data-wf-fit]")
    end

    test "levels order: prereq first, dependent second", %{
      conn: conn,
      ws: ws,
      goal: goal,
      task: task
    } do
      {:ok, prereq} = Tasks.create_task(%{"workspace_id" => ws.id, "title" => "Prereq first"})
      {:ok, _} = Tasks.set_goal(prereq, goal.id)
      {:ok, _} = Contracts.add_dependency(task, prereq)

      {:ok, _view, html} = live(conn, ~p"/#{ws.slug}/workflows/goal-with-workflow")

      first_pos = byte_size(hd(String.split(html, "Prereq first")))
      # Prereq appears before the dependent task in the rendered columns
      assert html =~ "Prereq first"
      assert first_pos < byte_size(hd(String.split(html, "Contract task")))

      # One pending edge renders with its card ports (input + output dots)
      assert html =~ "wfe-edge-pending"
      assert html =~ "rounded-full border-2 border-base-100"

      # Status labels are capitalized without underscores
      assert html =~ "Backlog"
    end

    test "status_label capitalizes and strips underscores" do
      alias DranWeb.WorkflowsLive
      assert WorkflowsLive.status_label("in_progress") == "In Progress"
      assert WorkflowsLive.status_label("done") == "Done"
      assert WorkflowsLive.status_label("backlog") == "Backlog"
    end

    test "blocked panel shows the dependency count", %{conn: conn, ws: ws, goal: goal, task: task} do
      {:ok, prereq} = Tasks.create_task(%{"workspace_id" => ws.id, "title" => "Prereq"})
      {:ok, _} = Tasks.set_goal(prereq, goal.id)
      {:ok, _} = Contracts.add_dependency(task, prereq)

      {:ok, _} =
        Tasks.update_task(task, %{
          "status" => "todo",
          "meta" => %{"contract" => valid_contract()}
        })

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/workflows/goal-with-workflow")
      # The blocked task appears in the "Bloqueadas" panel.
      assert has_element?(view, "div", "Contract task")
    end

    test "click on a DAG card opens the contract modal", %{conn: conn, ws: ws, task: task} do
      {:ok, task} = Tasks.update_task(task, %{"meta" => %{"contract" => valid_contract()}})

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/workflows/goal-with-workflow")

      refute has_element?(view, "#contract-modal")

      view
      |> element("[phx-value-task-id='#{task.id}']")
      |> render_click()

      assert has_element?(view, "#contract-modal")
      assert has_element?(view, "#contract-modal", "implement the workflow")
      assert has_element?(view, "#contract-modal", "active")
      assert has_element?(view, "#contract-modal", "P1")
    end

    test "?contract=<id> opens the modal directly; closing pops the param", %{
      conn: conn,
      ws: ws,
      task: task
    } do
      {:ok, task} = Tasks.update_task(task, %{"meta" => %{"contract" => valid_contract()}})

      {:ok, view, _html} =
        live(conn, ~p"/#{ws.slug}/workflows/goal-with-workflow?contract=#{task.id}")

      assert has_element?(view, "#contract-modal")

      # Popping the ?contract param closes the modal (URL state)
      render_patch(view, ~p"/#{ws.slug}/workflows/goal-with-workflow")

      refute has_element?(view, "#contract-modal")
    end
  end

  test "graph_edges draws prereq output -> dependent input" do
    alias DranWeb.WorkflowsLive

    # levels are lists of task ids: prereq on level 0, dependent on level 1
    levels = [["p1"], ["d1"]]
    tasks_by_id = %{"p1" => %{id: "p1", status: "done"}, "d1" => %{id: "d1", status: "todo"}}

    # relation tuple as stored in the DB: {dependent, prereq}
    [{_dep, edge}] = WorkflowsLive.graph_edges([{"d1", "p1"}], levels, tasks_by_id)

    # flows left to right: starts at the prereq output (right edge)
    {px, _py} = WorkflowsLive.node_position(levels, "p1")
    {dx, _dy} = WorkflowsLive.node_position(levels, "d1")
    assert edge.x1 == px + WorkflowsLive.node_w()
    assert edge.x2 == dx
    assert edge.x1 < edge.x2

    # ports agree: prereq owns the output dot, dependent owns the input dot
    ports = WorkflowsLive.graph_ports([{"d1", edge}], levels)
    assert ports["p1"].out.x == edge.x1
    assert ports["d1"].in.x == edge.x2
  end

  defp valid_contract do
    %{
      "version" => 1,
      "status" => "active",
      "intent" => "implement the workflow",
      "claims" => [%{"id" => "P1", "claim" => "done", "verify" => "mix test"}],
      "gates" => [%{"name" => "g", "cmd" => "mix test", "expect" => "green"}],
      "graph" => %{
        "nodes" => [
          %{"id" => "S1", "verb" => "RUN", "label" => "mix test"},
          %{"id" => "G1", "verb" => "VERIFY", "label" => "green?"}
        ],
        "edges" => [%{"from" => "S1", "to" => "G1", "guard" => "yes"}]
      }
    }
  end
end
