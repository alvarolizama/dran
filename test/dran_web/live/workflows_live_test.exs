defmodule DranWeb.WorkflowsLiveTest do
  @moduledoc """
  LiveView tests for the workflows model (post-pivot 2026-09): index of
  workflows with session actions, show with the steps DAG + sessions +
  runs with phase progress.
  """

  use DranWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Dran.{Contracts, Executions, Knowledge, Workflows}

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
      Knowledge.create_workspace(%{name: "Workflows Test", slug: "workflows-test"})

    {:ok, workflow} =
      Workflows.create_workflow(%{
        "workspace_id" => ws.id,
        "title" => "Deploy pipeline",
        "slug" => "deploy-pipeline"
      })

    {:ok, build} = Workflows.create_step(workflow, %{"title" => "Build", "slug" => "build"})
    {:ok, test} = Workflows.create_step(workflow, %{"title" => "Test", "slug" => "test-step"})
    {:ok, _deploy} = Workflows.create_step(workflow, %{"title" => "Deploy", "slug" => "deploy"})

    # Build → Test (Test depends on Build)
    {:ok, _} = Contracts.add_dependency(test, build)

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user, "test_user")
      |> Plug.Conn.put_session(:workspace_slug, ws.slug)
      |> Plug.Conn.put_session(:is_owner, true)

    {:ok, conn: conn, ws: ws, workflow: workflow}
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Index
  # ──────────────────────────────────────────────────────────────────────────

  describe "index" do
    test "renders one card per workflow with status and kind", %{
      conn: conn,
      ws: ws,
      workflow: workflow
    } do
      {:ok, view, html} = live(conn, ~p"/#{ws.slug}/workflows")

      assert html =~ "Deploy pipeline"
      assert html =~ "Nueva sesión"
      assert has_element?(view, "#workflow-card-#{workflow.id}")
      assert has_element?(view, "#workflow-card-#{workflow.id}", "evergreen")
      assert has_element?(view, "#workflow-card-#{workflow.id}", "Draft")
    end

    test "nueva sesión opens an in-flight session with the label", %{
      conn: conn,
      ws: ws,
      workflow: workflow
    } do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/workflows")

      view
      |> form("#workflow-session-form-#{workflow.id}")
      |> render_submit(%{"label" => "release 1"})

      assert has_element?(view, "#workflow-card-#{workflow.id}", "In Flight")

      sessions = Executions.list_sessions(workflow)
      assert [session] = sessions
      assert session.status == "in_flight"
      assert session.label == "release 1"
    end

    test "index shows in-flight sessions with progress", %{conn: conn, ws: ws, workflow: workflow} do
      {:ok, _session} = Executions.open_session(workflow, label: "live one")

      {:ok, view, html} = live(conn, ~p"/#{ws.slug}/workflows")

      assert html =~ "live one"
      assert html =~ "0/3"
      assert has_element?(view, "#workflow-card-#{workflow.id} progress")
    end

    test "abort button aborts an in-flight session from the index", %{
      conn: conn,
      ws: ws,
      workflow: workflow
    } do
      {:ok, session} = Executions.open_session(workflow, label: "to abort")

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/workflows")

      view
      |> element("#workflow-card-#{workflow.id} button[phx-value-session-id='#{session.id}']")
      |> render_click()

      session = Executions.get_session!(session.id)
      assert session.status == "aborted"
      assert session.finished_at
    end

    test "archived workflow renders no nueva sesión form", %{
      conn: conn,
      ws: ws,
      workflow: workflow
    } do
      {:ok, _} = Workflows.update_workflow(workflow, %{"status" => "archived"})

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/workflows")

      assert has_element?(view, "#workflow-card-#{workflow.id}")
      refute has_element?(view, "#workflow-card-#{workflow.id} form")
    end

    test "open_session with a foreign-workflow id is rejected (regression #2)", %{
      conn: conn,
      ws: ws
    } do
      # phx-value ids are client-forgeable: an authenticated user of ws must
      # not be able to open a session on a workflow of ANOTHER workspace by
      # sending the event with a foreign id.
      {:ok, other_ws} =
        Dran.Knowledge.create_workspace(%{
          name: "foreign #{System.unique_integer([:positive])}",
          slug: "foreign-#{System.unique_integer([:positive])}"
        })

      {:ok, foreign} =
        Workflows.create_workflow(%{
          "workspace_id" => other_ws.id,
          "title" => "F",
          "slug" => "f-#{System.unique_integer([:positive])}"
        })

      {:ok, _} = Workflows.create_step(foreign, %{"title" => "S", "slug" => "fs"})

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/workflows")

      render_hook(view, "open_session", %{"workflow-id" => foreign.id, "label" => "intrusion"})

      # No session was created on the foreign workflow.
      assert Executions.list_sessions(foreign) == []
    end

    test "abort_session with a foreign-workspace id is rejected (regression #2)", %{
      conn: conn,
      ws: ws,
      workflow: workflow
    } do
      {:ok, other_ws} =
        Dran.Knowledge.create_workspace(%{
          name: "foreign #{System.unique_integer([:positive])}",
          slug: "foreign-#{System.unique_integer([:positive])}"
        })

      {:ok, foreign_wf} =
        Workflows.create_workflow(%{
          "workspace_id" => other_ws.id,
          "title" => "F2",
          "slug" => "f2-#{System.unique_integer([:positive])}"
        })

      {:ok, _} = Workflows.create_step(foreign_wf, %{"title" => "S", "slug" => "fs2"})
      {:ok, foreign_session} = Executions.open_session(foreign_wf)

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/workflows")

      render_hook(view, "abort_session", %{"session-id" => foreign_session.id})

      # The foreign session was NOT aborted.
      assert Executions.get_session!(foreign_session.id).status == "in_flight"
      # Sanity: the same event with OUR session still works (guarded above).
      {:ok, mine} = Executions.open_session(workflow)

      view
      |> element("#workflow-card-#{workflow.id} button[phx-value-session-id='#{mine.id}']")
      |> render_click()

      assert Executions.get_session!(mine.id).status == "aborted"
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Show — steps DAG + sessions + runs
  # ──────────────────────────────────────────────────────────────────────────

  describe "show" do
    test "invalid workflow slug redirects back to the index without crashing", %{
      conn: conn,
      ws: ws
    } do
      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, ~p"/#{ws.slug}/workflows/not-a-real-workflow")

      assert to == ~p"/#{ws.slug}/workflows"
    end

    test "renders the steps DAG with pan/zoom controls and topological columns", %{
      conn: conn,
      ws: ws
    } do
      {:ok, view, html} = live(conn, ~p"/#{ws.slug}/workflows/deploy-pipeline")

      assert has_element?(view, "#wfe-canvas[phx-hook='WfPanZoom']")
      assert has_element?(view, "#wfe-canvas [data-wf-stage]")
      assert has_element?(view, "#wfe-canvas [data-wf-zoom='in']")
      assert has_element?(view, "#wfe-canvas [data-wf-zoom='out']")
      assert has_element?(view, "#wfe-canvas [data-wf-fit]")

      # Prereq (Build) appears before its dependent (Test) in the columns
      assert html =~ "Build"
      assert html =~ "Test"

      assert byte_size(hd(String.split(html, "Build"))) <
               byte_size(hd(String.split(html, "Test")))

      # A pending edge renders with its ports
      assert html =~ "wfe-edge-pending"
      assert html =~ "rounded-full border-2 border-base-100"
    end

    test "nueva sesión from the sessions panel opens a session and shows runs", %{
      conn: conn,
      ws: ws,
      workflow: workflow
    } do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/workflows/deploy-pipeline")

      view
      |> form("#workflow-session-form")
      |> render_submit(%{"label" => "first pass"})

      assert [session] = Executions.list_sessions(workflow)
      assert session.label == "first pass"
      assert session.workflow_id == workflow.id

      html = render(view)
      assert html =~ "first pass"
      assert html =~ "0/3"
      # The runs panel lists one pending run per step
      runs = Executions.list_runs(session)
      assert length(runs) == 3

      Enum.each(runs, fn run ->
        assert has_element?(view, "#run-row-#{run.id}", "Pending")
      end)
    end

    test "sessions panel lists sessions; clicking selects and shows its runs", %{
      conn: conn,
      ws: ws,
      workflow: workflow
    } do
      {:ok, s1} = Executions.open_session(workflow, label: "pass one")
      {:ok, s2} = Executions.open_session(workflow, label: "pass two")

      {:ok, view, _html} =
        live(conn, ~p"/#{ws.slug}/workflows/deploy-pipeline?session=#{s2.id}")

      assert has_element?(view, "#session-row-#{s1.id}")
      assert has_element?(view, "#session-row-#{s2.id}")
      assert render(view) =~ "pass two"

      # Deep-linked session is the selected one
      assert has_element?(view, "#session-row-#{s2.id}.border-primary")
      refute has_element?(view, "#session-row-#{s1.id}.border-primary")

      view |> element("#session-row-#{s1.id}") |> render_click()

      assert has_element?(view, "#session-row-#{s1.id}.border-primary")
      refute has_element?(view, "#session-row-#{s2.id}.border-primary")

      # The selected session's runs are visible
      runs = Executions.list_runs(s1)
      assert Enum.any?(runs, fn run -> has_element?(view, "#run-row-#{run.id}") end)
    end

    test "run lifecycle: start, phase progress and close turn chips and edges", %{
      conn: conn,
      ws: ws,
      workflow: workflow
    } do
      {:ok, session} = Executions.open_session(workflow)

      {:ok, view, _html} =
        live(conn, ~p"/#{ws.slug}/workflows/deploy-pipeline?session=#{session.id}")

      [build, test, _deploy] = runs = Executions.list_runs(session)

      Enum.each(runs, fn run ->
        assert has_element?(view, "#run-row-#{run.id}", "Pending")
      end)

      {:ok, _} = Executions.start_run(build)
      assert render(view) =~ "In Flight"

      # Phase progress reported by the agent. The :progress broadcast does
      # NOT reload the view (stop-the-world guard, review #8) — the phase
      # shows on the next structural refresh (start/close/select).
      {:ok, _} = Executions.update_progress(build.id, %{"phase" => "compiling"})
      {:ok, _} = Executions.close_run(build, status: "passed")

      html = render(view)
      assert has_element?(view, "#run-row-#{build.id}", "Passed")
      # The Build→Test edge turns done (prereq passed in the session)
      assert html =~ "wfe-edge-done"

      # Progress tally reflects the passed run
      assert html =~ "1/3"

      # ...and the dependent run (Test) — still pending — is NOT ready per
      # the frozen snapshot until its prereq passed (display only here).
      assert has_element?(view, "#run-row-#{test.id}", "Pending")
    end

    test "abort button aborts the session from the show panel", %{
      conn: conn,
      ws: ws,
      workflow: workflow
    } do
      {:ok, session} = Executions.open_session(workflow, label: "abort me")

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/workflows/deploy-pipeline")

      view
      |> element("button[phx-value-session-id='#{session.id}']")
      |> render_click()

      assert Executions.get_session!(session.id).status == "aborted"
      assert render(view) =~ "Aborted"
      # Its runs are shown as skipped
      runs = Executions.list_runs(session)

      Enum.each(runs, fn run ->
        assert has_element?(view, "#run-row-#{run.id}", "Skipped")
      end)
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Pure helpers
  # ──────────────────────────────────────────────────────────────────────────

  test "status_label capitalizes and strips underscores" do
    alias DranWeb.WorkflowsLive
    assert WorkflowsLive.status_label("in_flight") == "In Flight"
    assert WorkflowsLive.status_label("passed") == "Passed"
    assert WorkflowsLive.status_label("evergreen") == "Evergreen"
    assert WorkflowsLive.status_label(nil) == ""
  end

  test "session_pct and progress_label compute over finished runs" do
    alias DranWeb.WorkflowsLive

    progress = %{total: 4, pending: 1, in_flight: 1, passed: 1, failed: 1, skipped: 0}
    assert WorkflowsLive.session_pct(progress) == 50
    assert WorkflowsLive.progress_label(progress) == "2/4"

    empty = %{total: 0, pending: 0, in_flight: 0, passed: 0, failed: 0, skipped: 0}
    assert WorkflowsLive.session_pct(empty) == 0
    assert WorkflowsLive.progress_label(empty) == "0/0"
  end

  test "status chips map to badge classes" do
    alias DranWeb.WorkflowsLive

    assert WorkflowsLive.workflow_chip("active") == "badge-success"
    assert WorkflowsLive.workflow_chip("draft") == "badge-ghost"
    assert WorkflowsLive.workflow_chip("archived") == "badge-warning"

    assert WorkflowsLive.session_chip("in_flight") == "badge-primary"
    assert WorkflowsLive.session_chip("passed") == "badge-success"
    assert WorkflowsLive.session_chip("failed") == "badge-error"
    assert WorkflowsLive.session_chip("aborted") == "badge-warning"

    assert WorkflowsLive.run_chip("pending") == "badge-ghost"
    assert WorkflowsLive.run_chip("in_flight") == "badge-primary"
    assert WorkflowsLive.run_chip("passed") == "badge-success"
    assert WorkflowsLive.run_chip("failed") == "badge-error"
    assert WorkflowsLive.run_chip("skipped") == "badge-warning"
  end

  test "graph_edges draws prereq output -> dependent input, done when prereq passed" do
    alias DranWeb.WorkflowsLive

    # levels are lists of step ids: prereq on level 0, dependent on level 1
    levels = [["p1"], ["d1"]]
    passed = MapSet.new(["p1"])

    # relation tuple as stored in the DB: {dependent, prereq}
    [{_dep, edge}] = WorkflowsLive.graph_edges([{"d1", "p1"}], levels, passed)

    # flows left to right: starts at the prereq output (right edge)
    {px, _py} = WorkflowsLive.node_position(levels, "p1")
    {dx, _dy} = WorkflowsLive.node_position(levels, "d1")
    assert edge.x1 == px + WorkflowsLive.node_w()
    assert edge.x2 == dx
    assert edge.x1 < edge.x2
    assert edge.done

    # without a passed run the edge stays pending
    [{_dep, pending_edge}] = WorkflowsLive.graph_edges([{"d1", "p1"}], levels, MapSet.new())
    refute pending_edge.done

    # ports agree: prereq owns the output dot, dependent owns the input dot
    ports = WorkflowsLive.graph_ports([{"d1", edge}], levels)
    assert ports["p1"].out.x == edge.x1
    assert ports["d1"].in.x == edge.x2
  end
end
