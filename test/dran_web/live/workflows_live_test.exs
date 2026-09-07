defmodule DranWeb.WorkflowsLiveTest do
  @moduledoc """
  LiveView tests for the workflows model (post-pivot 2026-09): index of
  workflows with session actions, show with the steps DAG + sessions +
  runs with phase progress.
  """

  use DranWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Dran.{Contracts, Executions, Knowledge, Repo, Workflows}

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
      assert has_element?(view, "#workflow-card-#{workflow.id}", "Evergreen")
      assert has_element?(view, "#workflow-card-#{workflow.id}", "Draft")
    end

    test "nueva sesión opens an in-flight session with an auto-generated label", %{
      conn: conn,
      ws: ws,
      workflow: workflow
    } do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/workflows")

      view
      |> form("#workflow-session-form-#{workflow.id}")
      |> render_submit()

      assert has_element?(view, "#workflow-card-#{workflow.id}", "In Flight")

      sessions = Executions.list_sessions(workflow)
      assert [session] = sessions
      assert session.status == "in_flight"
      assert session.label == "Sesión 1"
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

    test "archived workflow leaves the main grid and renders no form in the archived section", %{
      conn: conn,
      ws: ws,
      workflow: workflow
    } do
      {:ok, _} = Workflows.update_workflow(workflow, %{"status" => "archived"})

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/workflows")

      # Archivados fuera de la grid principal (patrón pages)
      refute has_element?(view, "#workflow-card-#{workflow.id}")

      view
      |> element("[data-testid='toggle-archived']")
      |> render_click()

      assert has_element?(view, "[data-testid='archived-workflow-#{workflow.slug}']")
      refute has_element?(view, "[data-testid='archived-workflow-#{workflow.slug}'] form")
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
  # Index — kind filters (multi-select URL), archived toggle, create modal
  # ──────────────────────────────────────────────────────────────────────────

  describe "index filters and archiving" do
    test "kind filter via URL shows only matching kinds", %{
      conn: conn,
      ws: ws,
      workflow: workflow
    } do
      {:ok, one_shot} =
        Workflows.create_workflow(%{
          "workspace_id" => ws.id,
          "title" => "One Shot Flow",
          "slug" => "one-shot-flow",
          "kind" => "one_shot"
        })

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/workflows?kind=evergreen")

      assert has_element?(view, "#workflow-card-#{workflow.id}")
      refute has_element?(view, "#workflow-card-#{one_shot.id}")

      # Multi-select: both kinds selected shows both.
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/workflows?kind=evergreen,one_shot")

      assert has_element?(view, "#workflow-card-#{workflow.id}")
      assert has_element?(view, "#workflow-card-#{one_shot.id}")

      # Unknown values are dropped — only the valid kind filters.
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/workflows?kind=bogus,evergreen")

      assert has_element?(view, "#workflow-card-#{workflow.id}")
      refute has_element?(view, "#workflow-card-#{one_shot.id}")
    end

    test "toggle_kind event pushes a patch with the URL filter state", %{
      conn: conn,
      ws: ws,
      workflow: workflow
    } do
      {:ok, one_shot} =
        Workflows.create_workflow(%{
          "workspace_id" => ws.id,
          "title" => "One Shot Flow",
          "slug" => "one-shot-flow",
          "kind" => "one_shot"
        })

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/workflows")

      # Open the kind menu first, then toggle one_shot on.
      view
      |> element("[data-testid='kind-filter-toggle']")
      |> render_click()

      view
      |> element("[data-testid='kind-option-one_shot']")
      |> render_click()

      assert has_element?(view, "#workflow-card-#{one_shot.id}")
      refute has_element?(view, "#workflow-card-#{workflow.id}")

      # Toggling again clears it back to the unfiltered list (menu stays open
      # across patches, so no re-open needed).
      view
      |> element("[data-testid='kind-option-one_shot']")
      |> render_click()

      assert has_element?(view, "#workflow-card-#{workflow.id}")
    end

    test "archive_workflow moves the card to the archived section; unarchive restores it", %{
      conn: conn,
      ws: ws,
      workflow: workflow
    } do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/workflows")

      view
      |> element("[data-testid='archive-btn-#{workflow.slug}']")
      |> render_click()

      refute has_element?(view, "#workflow-card-#{workflow.id}")

      view
      |> element("[data-testid='toggle-archived']")
      |> render_click()

      assert has_element?(view, "[data-testid='archived-workflow-#{workflow.slug}']")

      view
      |> element("[data-testid='unarchive-btn-#{workflow.slug}']")
      |> render_click()

      refute has_element?(view, "[data-testid='archived-workflow-#{workflow.slug}']")
      assert has_element?(view, "#workflow-card-#{workflow.id}")
    end

    test "status filter via URL and toggle_status event (draft vs active)", %{
      conn: conn,
      ws: ws,
      workflow: workflow
    } do
      {:ok, active} =
        Workflows.create_workflow(%{
          "workspace_id" => ws.id,
          "title" => "Active Flow",
          "slug" => "active-flow",
          "status" => "active"
        })

      # ?status=draft hides the active one; ?status=active hides the draft one.
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/workflows?status=draft")
      assert has_element?(view, "#workflow-card-#{workflow.id}")
      refute has_element?(view, "#workflow-card-#{active.id}")

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/workflows?status=active")
      assert has_element?(view, "#workflow-card-#{active.id}")
      refute has_element?(view, "#workflow-card-#{workflow.id}")

      # Combined filters compose: Active Flow (evergreen+active) survives,
      # the draft fixture does not.
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/workflows?kind=evergreen&status=active")
      refute has_element?(view, "#workflow-card-#{workflow.id}")
      assert has_element?(view, "#workflow-card-#{active.id}")

      # UI toggle: open menu, click draft, assert active hidden and patch state.
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/workflows")

      view
      |> element("[data-testid='status-filter-toggle']")
      |> render_click()

      view
      |> element("[data-testid='status-option-draft']")
      |> render_click()

      assert has_element?(view, "#workflow-card-#{workflow.id}")
      refute has_element?(view, "#workflow-card-#{active.id}")
    end

    test "create modal opens via ?new=true, validates and saves a new workflow", %{
      conn: conn,
      ws: ws
    } do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/workflows?new=true")

      assert has_element?(view, "#workflow-resource-modal")
      assert has_element?(view, "#workflow-modal-form")

      view
      |> form("#workflow-modal-form", workflow: %{"title" => "Nuevo flujo", "kind" => "one_shot"})
      |> render_change()

      assert has_element?(view, "#workflow-resource-modal")

      view
      |> form("#workflow-modal-form")
      |> render_submit(workflow: %{"title" => "Nuevo flujo", "kind" => "one_shot"})

      assert workflow = Workflows.get_workflow_by_slug("nuevo-flujo", ws.id)
      assert workflow.kind == "one_shot"

      # Modal closed — save lands on the new workflow's show page.
      refute has_element?(view, "#workflow-resource-modal")
      assert render(view) =~ "Nuevo flujo"

      # And the new workflow is on the index grid.
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/workflows")
      assert has_element?(view, "#workflow-card-#{workflow.id}")
    end

    test "create modal submit without title shows validation error", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/workflows?new=true")

      view
      |> form("#workflow-modal-form")
      |> render_submit(workflow: %{"title" => ""})

      assert has_element?(view, "#workflow-resource-modal")
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

      assert has_element?(view, "#wfe-canvas[phx-hook='WfCanvas']")
      assert has_element?(view, "#wfe-canvas [data-wf-stage]")
      assert has_element?(view, "#wfe-canvas [data-wf-zoom='in']")
      assert has_element?(view, "#wfe-canvas [data-wf-zoom='out']")
      assert has_element?(view, "#wfe-canvas [data-wf-fit]")
      assert has_element?(view, "#wfe-canvas [aria-label='Ordenar por nivel']")
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
      |> render_submit()

      assert [session] = Executions.list_sessions(workflow)
      assert session.label == "Sesión 1"
      assert session.workflow_id == workflow.id

      html = render(view)
      assert html =~ "Sesión 1"
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

    test "delete_session removes a closed session with its runs from the show panel", %{
      conn: conn,
      ws: ws,
      workflow: workflow
    } do
      {:ok, session} = Executions.open_session(workflow, label: "dead pass")
      {:ok, _} = Executions.abort_session(Repo.get!(Dran.WorkflowSession, session.id))

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/workflows/deploy-pipeline")

      # The trash button exists only for closed sessions.
      assert has_element?(view, "[data-testid='delete-session-#{session.id}']")

      view
      |> element("[data-testid='delete-session-#{session.id}']")
      |> render_click()

      assert Repo.get(Dran.WorkflowSession, session.id) == nil
      assert Repo.all(from(r in Dran.Run, where: r.session_id == ^session.id)) == []
      refute has_element?(view, "#session-row-#{session.id}")
      assert render(view) =~ "Sesión eliminada"
    end

    test "edit-workflow modal changes kind while sessionless; kind locks once sessions exist", %{
      conn: conn,
      ws: ws
    } do
      {:ok, flow} =
        Workflows.create_workflow(%{
          "workspace_id" => ws.id,
          "title" => "Empty flow",
          "slug" => "empty-flow"
        })

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/workflows/empty-flow?edit=true")

      assert has_element?(view, "#workflow-edit-modal")

      # Kind editable BEFORE any session exists (pre-execution decision).
      view
      |> element("#workflow-edit-form")
      |> render_submit(%{workflow: %{"title" => "Empty flow", "kind" => "one_shot"}})

      assert Repo.get!(Dran.Workflow, flow.id).kind == "one_shot"

      # A session appears → the same modal renders the kind select disabled.
      {:ok, _step} = Workflows.create_step(flow, %{"title" => "S", "slug" => "s"})
      {:ok, session} = Executions.open_session(Repo.get!(Dran.Workflow, flow.id))
      [run] = Executions.list_runs(Repo.get!(Dran.WorkflowSession, session.id))
      {:ok, run} = Executions.start_run(run)
      {:ok, _} = Executions.close_run(run, status: "passed", outcome: "ok")

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/workflows/empty-flow?edit=true")
      assert has_element?(view, "#workflow-edit-modal select[name='workflow[kind]'][disabled]")

      # Forged submit changing kind: refused (context guard, not just UI).
      {:error, :kind_locked} =
        Workflows.update_workflow(Repo.get!(Dran.Workflow, flow.id), %{"kind" => "evergreen"})

      assert Repo.get!(Dran.Workflow, flow.id).kind == "one_shot"
    end

    test "delete_session is refused for an in_flight session (no button, guard flash)", %{
      conn: conn,
      ws: ws,
      workflow: workflow
    } do
      {:ok, session} = Executions.open_session(workflow, label: "live pass")

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/workflows/deploy-pipeline")

      # In-flight: no trash button rendered (only abort).
      refute has_element?(view, "[data-testid='delete-session-#{session.id}']")

      # A forged event is refused by the context anyway.
      render_hook(view, "delete_session", %{"session-id" => session.id})
      assert Repo.get!(Dran.WorkflowSession, session.id).status == "in_flight"
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Show — step modal (create / edit / delete) — ?new_step=true / ?step=<id>
  # ──────────────────────────────────────────────────────────────────────────

  describe "step modal" do
    test "?new_step=true opens the create modal and saves a step with auto slug and position", %{
      conn: conn,
      ws: ws,
      workflow: workflow
    } do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/workflows/deploy-pipeline?new_step=true")

      assert has_element?(view, "#step-resource-modal")
      assert has_element?(view, "#step-modal-form")

      view
      |> form("#step-modal-form", step: %{"title" => "Lint"})
      |> render_submit()

      assert step = Enum.find(Workflows.list_steps(workflow), &(&1.slug == "lint"))
      assert step.title == "Lint"
      # Appended at the end: position = max + 100. Setup already created
      # 3 steps (100/200/300) → this one lands at 400 (gap convention).
      assert step.position == 400

      # Modal closed, flash confirms, and the node is on the DAG.
      refute has_element?(view, "#step-resource-modal")
      assert render(view) =~ "Lint"
    end

    test "create with 'después de' checked links the step behind the last step", %{
      conn: conn,
      ws: ws,
      workflow: workflow
    } do
      deploy = Enum.find(Workflows.list_steps(workflow), &(&1.slug == "deploy"))

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/workflows/deploy-pipeline?new_step=true")

      # The checkbox is pre-set to the last step by position (deploy).
      assert has_element?(
               view,
               "#step-resource-modal input[type='checkbox'][value='#{deploy.id}']"
             )

      view
      |> form("#step-modal-form",
        step: %{"title" => "Notify"},
        new_step: %{"after" => deploy.id}
      )
      |> render_submit()

      notify = Enum.find(Workflows.list_steps(workflow), &(&1.slug == "notify"))
      assert notify

      # The depends_on edge exists: notify depends_on deploy.
      edges = Contracts.dependency_edges(Enum.map(Workflows.list_steps(workflow), & &1.id), :step)
      assert {notify.id, deploy.id} in edges

      # And the DAG places notify one level after deploy (levels/1 returns
      # lists of step ids per level, 0 = leftmost).
      levels = workflow |> Workflows.list_steps() |> Contracts.levels()

      deploy_level = Enum.find_index(levels, &Enum.member?(&1, deploy.id))
      notify_level = Enum.find_index(levels, &Enum.member?(&1, notify.id))

      assert notify_level == deploy_level + 1
    end

    test "create with 'después de' unchecked creates the step WITHOUT an edge", %{
      conn: conn,
      ws: ws,
      workflow: workflow
    } do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/workflows/deploy-pipeline?new_step=true")

      view
      |> form("#step-modal-form", step: %{"title" => "Loose"})
      |> render_submit()

      loose = Enum.find(Workflows.list_steps(workflow), &(&1.slug == "loose"))
      assert loose

      step_ids = Enum.map(Workflows.list_steps(workflow), & &1.id)
      edges = Contracts.dependency_edges(step_ids, :step)
      assert {loose.id, loose.id} not in edges
      assert Enum.all?(edges, fn {src, _tgt} -> src != loose.id end)

      # A root: level 0 in the DAG.
      levels = workflow |> Workflows.list_steps() |> Contracts.levels()
      assert Enum.member?(hd(levels), loose.id)
    end

    test "create with a forged 'after' step id from ANOTHER workflow ignores the edge", %{
      conn: conn,
      ws: ws,
      workflow: workflow
    } do
      {:ok, other_ws} =
        Dran.Knowledge.create_workspace(%{
          name: "after foreign #{System.unique_integer([:positive])}",
          slug: "after-foreign-#{System.unique_integer([:positive])}"
        })

      {:ok, other_wf} =
        Workflows.create_workflow(%{workspace_id: other_ws.id, title: "Other", slug: "other-wf"})

      {:ok, other_step} = Workflows.create_step(other_wf, %{title: "Other step", slug: "other"})

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/workflows/deploy-pipeline?new_step=true")

      # Hand-crafted submit: the checkbox only ever offers this workflow's
      # steps, so a foreign id is what a tampered client would send.
      render_submit(view, "save_step", %{
        "step" => %{"title" => "Hijack"},
        "new_step" => %{"after" => other_step.id}
      })

      hijack = Enum.find(Workflows.list_steps(workflow), &(&1.slug == "hijack"))
      assert hijack

      # The cross-workflow edge was NOT created; the step saved anyway.
      step_ids = Enum.map(Workflows.list_steps(workflow), & &1.id)
      assert {hijack.id, other_step.id} not in Contracts.dependency_edges(step_ids, :step)
    end

    test "create submit without title shows validation error and keeps the modal open", %{
      conn: conn,
      ws: ws
    } do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/workflows/deploy-pipeline?new_step=true")

      view
      |> form("#step-modal-form")
      |> render_submit(step: %{"title" => ""})

      assert has_element?(view, "#step-resource-modal")
    end

    test "save_step without an open modal is a flash, not a crash", %{
      conn: conn,
      ws: ws,
      workflow: workflow
    } do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/workflows/deploy-pipeline")

      # Forged phx-submit with no ?new_step/?step param → step_modal is nil.
      render_submit(view, "save_step", %{"step" => %{"title" => "Ghost", "slug" => "ghost"}})

      assert render(view) =~ "No hay ningún step abierto"

      refute Enum.any?(Workflows.list_steps(workflow), &(&1.slug == "ghost"))
    end

    test "clicking a DAG node's pencil opens the edit modal prefilled; save updates the step", %{
      conn: conn,
      ws: ws,
      workflow: workflow
    } do
      build = Enum.find(Workflows.list_steps(workflow), &(&1.slug == "build"))

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/workflows/deploy-pipeline")

      view
      |> element(
        "div[data-testid='step-node'][data-step-id='#{build.id}'] [data-testid='step-edit']"
      )
      |> render_click()

      assert has_element?(view, "#step-resource-modal", "Edit Step")

      # Prefilled with the existing step data.
      input_html = view |> element("#step_title") |> render()
      assert input_html =~ ~s(name="step[title]")
      assert input_html =~ ~s(value="Build")

      view
      |> form("#step-modal-form", step: %{"title" => "Build image"})
      |> render_submit()

      assert Workflows.get_step!(build.id).title == "Build image"
      refute has_element?(view, "#step-resource-modal")
    end

    test "duplicate slug in the workspace shows the changeset error", %{
      conn: conn,
      ws: ws,
      workflow: workflow
    } do
      assert Enum.find(Workflows.list_steps(workflow), &(&1.slug == "test-step"))

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/workflows/deploy-pipeline?new_step=true")

      view
      |> form("#step-modal-form", step: %{"title" => "Test step"})
      |> render_submit()

      # Auto-managed slug: a colliding title gets a random hex suffix, so the
      # step is ALWAYS created — uniqueness never blocks the user anymore.
      steps = Workflows.list_steps(workflow)
      assert Enum.count(steps, &(&1.title == "Test step")) == 1
      assert Enum.find(steps, &(&1.title == "Test step")).slug != "test-step"
      refute has_element?(view, "#step-resource-modal")
    end

    test "delete button removes the step and closes the modal", %{
      conn: conn,
      ws: ws,
      workflow: workflow
    } do
      build = Enum.find(Workflows.list_steps(workflow), &(&1.slug == "build"))

      {:ok, view, _html} =
        live(conn, ~p"/#{ws.slug}/workflows/deploy-pipeline?step=#{build.id}")

      assert has_element?(view, "#step-resource-modal")

      view
      |> element("[data-testid='delete-step']")
      |> render_click()

      assert_raise Ecto.NoResultsError, fn -> Workflows.get_step!(build.id) end
      refute has_element?(view, "#step-resource-modal")
    end

    test "delete blocked by domain guard shows the error INSIDE the modal", %{
      conn: conn,
      ws: ws,
      workflow: workflow
    } do
      # A step referenced by an open session's snapshot cannot be deleted:
      # open a session (snapshot freezes the steps) and start its run.
      {:ok, session} = Executions.open_session(workflow, label: "guard")

      build = Enum.find(Workflows.list_steps(workflow), &(&1.slug == "build"))

      [run] = Enum.filter(Executions.list_runs(session), &(&1.step_id == build.id))
      {:ok, _claimed} = Executions.start_run(run)

      {:ok, view, _html} =
        live(conn, ~p"/#{ws.slug}/workflows/deploy-pipeline?step=#{build.id}")

      assert has_element?(view, "#step-resource-modal")

      view
      |> element("[data-testid='delete-step']")
      |> render_click()

      # Modal stays open with the inline guard error; the step survives.
      assert has_element?(view, "#step-resource-modal")
      assert has_element?(view, "[data-testid='step-delete-error']")
      assert Workflows.get_step!(build.id)
    end

    test "a step of ANOTHER workspace does not open in the modal (row-level auth)", %{
      conn: conn,
      ws: ws
    } do
      {:ok, other_ws} =
        Dran.Knowledge.create_workspace(%{
          name: "foreign #{System.unique_integer([:positive])}",
          slug: "foreign-#{System.unique_integer([:positive])}"
        })

      {:ok, foreign_wf} =
        Workflows.create_workflow(%{
          "workspace_id" => other_ws.id,
          "title" => "F3",
          "slug" => "f3-#{System.unique_integer([:positive])}"
        })

      {:ok, foreign_step} = Workflows.create_step(foreign_wf, %{"title" => "S", "slug" => "fs3"})

      {:ok, view, _html} =
        live(conn, ~p"/#{ws.slug}/workflows/deploy-pipeline?step=#{foreign_step.id}")

      refute has_element?(view, "#step-resource-modal")
    end

    # ── Conexiones: listar y romper desde el modal (alta sigue en canvas) ──

    test "edit modal lists the step's connections (outgoing and incoming)", %{
      conn: conn,
      ws: ws,
      workflow: workflow
    } do
      build = Enum.find(Workflows.list_steps(workflow), &(&1.slug == "build"))
      test_step = Enum.find(Workflows.list_steps(workflow), &(&1.slug == "test-step"))
      deploy = Enum.find(Workflows.list_steps(workflow), &(&1.slug == "deploy"))

      # Incoming: deploy depends on test-step (setup wires build→test only,
      # so wire deploy→test here like the break test does). Both edges must
      # exist BEFORE the view renders.
      {:ok, _} = Contracts.add_dependency(deploy, test_step)

      {:ok, view, _html} =
        live(conn, ~p"/#{ws.slug}/workflows/deploy-pipeline?step=#{test_step.id}")

      assert has_element?(view, "[data-testid='step-connections']")
      # Outgoing: test-step depends on build.
      assert has_element?(view, "[data-testid='unlink-out-#{build.id}']")

      html = view |> element("[data-testid='step-connections']") |> render()
      assert html =~ "Build"
      assert html =~ "Deploy"
    end

    test "breaking an outgoing connection from the modal removes the depends_on edge", %{
      conn: conn,
      ws: ws,
      workflow: workflow
    } do
      build = Enum.find(Workflows.list_steps(workflow), &(&1.slug == "build"))
      test_step = Enum.find(Workflows.list_steps(workflow), &(&1.slug == "test-step"))

      {:ok, view, _html} =
        live(conn, ~p"/#{ws.slug}/workflows/deploy-pipeline?step=#{test_step.id}")

      view
      |> element("[data-testid='unlink-out-#{build.id}']")
      |> render_click()

      step_ids = Enum.map(Workflows.list_steps(workflow), & &1.id)
      assert {test_step.id, build.id} not in Contracts.dependency_edges(step_ids, :step)
      # Both steps survive — breaking a connection never deletes steps.
      assert Workflows.get_step!(build.id)
      assert Workflows.get_step!(test_step.id)
      # Modal stays open (URL unchanged) and the section refreshes: build
      # left the outgoing list.
      assert has_element?(view, "#step-resource-modal")
      refute has_element?(view, "[data-testid='unlink-out-#{build.id}']")
    end

    test "breaking an incoming connection from the modal removes the edge", %{
      conn: conn,
      ws: ws,
      workflow: workflow
    } do
      test_step = Enum.find(Workflows.list_steps(workflow), &(&1.slug == "test-step"))
      deploy = Enum.find(Workflows.list_steps(workflow), &(&1.slug == "deploy"))

      # The setup only wires build→test; give test an incoming edge too.
      {:ok, _} = Contracts.add_dependency(deploy, test_step)

      {:ok, view, _html} =
        live(conn, ~p"/#{ws.slug}/workflows/deploy-pipeline?step=#{test_step.id}")

      view
      |> element("[data-testid='unlink-in-#{deploy.id}']")
      |> render_click()

      step_ids = Enum.map(Workflows.list_steps(workflow), & &1.id)
      assert {deploy.id, test_step.id} not in Contracts.dependency_edges(step_ids, :step)
      assert Workflows.get_step!(deploy.id)
      assert Workflows.get_step!(test_step.id)
    end

    # ── Contrato: ver y editar (columnas + embeds) desde el modal ──────────────

    test "edit modal shows the step's contract JSON in the textarea", %{
      conn: conn,
      ws: ws,
      workflow: workflow
    } do
      contract = %{
        "intent" => "Ship the login flow",
        "claims" => [%{"id" => "P1", "claim" => "form validates", "verify" => "mix test"}],
        "gates" => [%{"name" => "test", "cmd" => "mix test", "expect" => "exit 0"}]
      }

      build = Enum.find(Workflows.list_steps(workflow), &(&1.slug == "build"))

      {:ok, _} = Workflows.update_step(build, contract_attrs(contract))

      {:ok, view, _html} =
        live(conn, ~p"/#{ws.slug}/workflows/deploy-pipeline?step=#{build.id}")

      assert has_element?(view, "[data-testid='step-contract']")
      html = view |> element("[data-testid='step-contract']") |> render()
      assert html =~ "Ship the login flow"
      assert html =~ "mix test"
    end

    test "grafo tab renders the canvas container and node positions (x/y) round-trip", %{
      conn: conn,
      ws: ws,
      workflow: workflow
    } do
      contract = %{
        "intent" => "Ship the login flow",
        "graph" => %{
          "nodes" => [
            %{"id" => "S1", "verb" => "READ", "label" => "router.ex", "x" => 96, "y" => 48},
            %{"id" => "G1", "verb" => "VERIFY", "label" => "tests green?"}
          ],
          "edges" => [%{"from" => "S1", "to" => "G1"}]
        }
      }

      build = Enum.find(Workflows.list_steps(workflow), &(&1.slug == "build"))
      {:ok, _} = Workflows.update_step(build, contract_attrs(contract))

      {:ok, view, _html} =
        live(conn, ~p"/#{ws.slug}/workflows/deploy-pipeline?step=#{build.id}")

      # Canvas container server-rendered dentro del panel grafo
      assert has_element?(view, "[data-panel='grafo'] [data-graph-canvas]")
      assert has_element?(view, "[data-panel='grafo'] [data-gc-empty]")

      # x/y persistidos en el embed (el layout del canvas sobrevive al guardado)
      build = Workflows.get_step!(build.id)
      node = Enum.find(build.graph.nodes, &(&1.id == "S1"))
      assert node.x == 96
      assert node.y == 48

      # Nodo sin x/y queda nil → auto-layout client-side
      g1 = Enum.find(build.graph.nodes, &(&1.id == "G1"))
      assert is_nil(g1.x) and is_nil(g1.y)

      # El JSON del contrato que alimenta al canvas incluye las coords
      # (el HTML escapa las comillas como &quot;)
      html = view |> element("[data-testid='step-contract']") |> render()
      assert html =~ "&quot;x&quot;: 96"
      assert html =~ "&quot;y&quot;: 48"
    end

    test "typing invalid JSON shows inline lint feedback without blocking the form", %{
      conn: conn,
      ws: ws,
      workflow: workflow
    } do
      build = Enum.find(Workflows.list_steps(workflow), &(&1.slug == "build"))

      {:ok, view, _html} =
        live(conn, ~p"/#{ws.slug}/workflows/deploy-pipeline?step=#{build.id}")

      view
      |> form("#step-modal-form", step: %{"contract_json" => "{\"intent\": "})
      |> render_change()

      assert has_element?(view, "[data-testid='contract-lint-error']")

      # Typing a VALID contract flips the feedback to ok.
      view
      |> form("#step-modal-form", step: %{"contract_json" => valid_contract_json()})
      |> render_change()

      assert has_element?(view, "[data-testid='contract-lint-ok']")
    end

    test "saving the modal with a valid contract keeps canvas position", %{
      conn: conn,
      ws: ws,
      workflow: workflow
    } do
      build = Enum.find(Workflows.list_steps(workflow), &(&1.slug == "build"))

      # The canvas materializes pos_x/pos_y on first drag; the modal save must
      # not clobber it.
      {:ok, _} = Workflows.update_step(build, %{"pos_x" => 40, "pos_y" => 60})

      {:ok, view, _html} =
        live(conn, ~p"/#{ws.slug}/workflows/deploy-pipeline?step=#{build.id}")

      view
      |> form("#step-modal-form",
        step: %{"title" => "Build", "contract_json" => valid_contract_json()}
      )
      |> render_submit()

      saved = Workflows.get_step!(build.id)
      assert saved.intent == "Ship the login flow"
      assert saved.pos_x == 40 and saved.pos_y == 60
    end

    test "saving with unparseable JSON leaves the stored contract untouched", %{
      conn: conn,
      ws: ws,
      workflow: workflow
    } do
      build = Enum.find(Workflows.list_steps(workflow), &(&1.slug == "build"))
      contract = %{"intent" => "Keep me"}

      {:ok, _} = Workflows.update_step(build, contract_attrs(contract))

      {:ok, view, _html} =
        live(conn, ~p"/#{ws.slug}/workflows/deploy-pipeline?step=#{build.id}")

      view
      |> form("#step-modal-form", step: %{"contract_json" => "not json"})
      |> render_submit()

      assert Workflows.get_step!(build.id).intent == "Keep me"
    end

    test "clearing the textarea removes the contract from the step", %{
      conn: conn,
      ws: ws,
      workflow: workflow
    } do
      build = Enum.find(Workflows.list_steps(workflow), &(&1.slug == "build"))

      {:ok, _} = Workflows.update_step(build, %{"intent" => "x"})

      {:ok, view, _html} =
        live(conn, ~p"/#{ws.slug}/workflows/deploy-pipeline?step=#{build.id}")

      view
      |> form("#step-modal-form", step: %{"contract_json" => ""})
      |> render_submit()

      refute Workflows.get_step!(build.id).intent
    end

    test "a lint-failing contract shows why (missing intent)", %{
      conn: conn,
      ws: ws,
      workflow: workflow
    } do
      build = Enum.find(Workflows.list_steps(workflow), &(&1.slug == "build"))

      {:ok, view, _html} =
        live(conn, ~p"/#{ws.slug}/workflows/deploy-pipeline?step=#{build.id}")

      view
      |> form("#step-modal-form", step: %{"contract_json" => ~s({"status": "draft"})})
      |> render_change()

      html = view |> element("[data-testid='contract-lint-error']") |> render()
      assert html =~ "intent"
    end
  end

  # JSON contract string → step attrs (columns + embeds). Used to seed
  # contracts directly in tests, bypassing the modal serialization.
  defp contract_attrs(json) when is_map(json) do
    %{"intent" => json["intent"]}
    |> then(fn attrs ->
      case json["claims"] do
        nil -> attrs
        claims -> Map.put(attrs, "claims", claims)
      end
    end)
    |> then(fn attrs ->
      case json["gates"] do
        nil -> attrs
        gates -> Map.put(attrs, "gates", gates)
      end
    end)
    |> then(fn attrs ->
      case json["graph"] do
        nil -> attrs
        graph -> Map.put(attrs, "graph", graph)
      end
    end)
    |> then(fn attrs ->
      case json["context_snapshot"] do
        nil -> attrs
        ctx -> Map.put(attrs, "context_snapshot", ctx)
      end
    end)
  end

  # Lint-passing fixture (same shape as the context tests' valid_contract):
  # intent, claims with verify, gates with cmd/expect, graph with a VERIFY
  # funnel.
  defp valid_contract_json do
    ~s({"intent": "Ship the login flow", "status": "active", "claims": [{"id": "P1", "claim": "form validates", "verify": "mix test"}], "gates": [{"name": "compile", "cmd": "mix compile --warnings-as-errors", "expect": "exit 0"}], "graph": {"nodes": [{"id": "S1", "verb": "READ", "label": "router.ex"}, {"id": "S2", "verb": "RUN", "label": "mix test"}, {"id": "G1", "verb": "VERIFY", "label": "tests green?"}], "edges": [{"from": "S1", "to": "S2", "guard": "yes"}, {"from": "S2", "to": "G1", "guard": "yes"}]}})
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

  # ──────────────────────────────────────────────────────────────────────────
  # Canvas editor (free layout + port-to-port edges)
  # ──────────────────────────────────────────────────────────────────────────

  describe "canvas editor" do
    test "move_step persists pos_x/pos_y for the dragged card", %{
      conn: conn,
      ws: ws,
      workflow: workflow
    } do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/workflows/#{workflow.slug}")
      build = Enum.find(Workflows.list_steps(workflow), &(&1.slug == "build"))

      view
      |> element("#wfe-canvas")
      |> render_hook("move_step", %{"step-id" => build.id, "x" => "320", "y" => "160"})

      saved = Workflows.get_step!(build.id)
      assert saved.pos_x == 320 and saved.pos_y == 160
    end

    test "move_step with a forged step id is a silent no-op", %{
      conn: conn,
      ws: ws,
      workflow: workflow
    } do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/workflows/#{workflow.slug}")
      build = Enum.find(Workflows.list_steps(workflow), &(&1.slug == "build"))

      view
      |> element("#wfe-canvas")
      |> render_hook("move_step", %{"step-id" => Ecto.UUID.generate(), "x" => "10", "y" => "10"})

      assert Workflows.get_step!(build.id).pos_x == nil
    end

    test "connect_steps creates the depends_on edge; self loop is rejected", %{
      conn: conn,
      ws: ws,
      workflow: workflow
    } do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/workflows/#{workflow.slug}")
      steps = Workflows.list_steps(workflow)
      build = Enum.find(steps, &(&1.slug == "build"))
      deploy = Enum.find(steps, &(&1.slug == "deploy"))

      view
      |> element("#wfe-canvas")
      |> render_hook("connect_steps", %{
        "prereq-id" => build.id,
        "dependent-id" => deploy.id
      })

      assert build.id in Contracts.prerequisite_ids(Workflows.get_step!(deploy.id))

      # Self-dependency → cycle guard del contexto.
      view
      |> element("#wfe-canvas")
      |> render_hook("connect_steps", %{
        "prereq-id" => build.id,
        "dependent-id" => build.id
      })

      refute build.id in Contracts.prerequisite_ids(Workflows.get_step!(build.id))
    end

    test "remove_dependency deletes the edge", %{conn: conn, ws: ws, workflow: workflow} do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/workflows/#{workflow.slug}")
      steps = Workflows.list_steps(workflow)
      build = Enum.find(steps, &(&1.slug == "build"))
      test_step = Enum.find(steps, &(&1.slug == "test-step"))

      assert build.id in Contracts.prerequisite_ids(Workflows.get_step!(test_step.id))

      view
      |> element("#wfe-canvas")
      |> render_hook("remove_dependency", %{
        "dependent-id" => test_step.id,
        "prereq-id" => build.id
      })

      assert Contracts.prerequisite_ids(Workflows.get_step!(test_step.id)) == []
    end

    test "edge_add_step inserts a NEW step in the middle of the edge", %{
      conn: conn,
      ws: ws,
      workflow: workflow
    } do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/workflows/#{workflow.slug}")
      steps = Workflows.list_steps(workflow)
      build = Enum.find(steps, &(&1.slug == "build"))
      test_step = Enum.find(steps, &(&1.slug == "test-step"))

      assert build.id in Contracts.prerequisite_ids(Workflows.get_step!(test_step.id))

      view
      |> element("#wfe-canvas")
      |> render_hook("edge_add_step", %{
        "dependent-id" => test_step.id,
        "prereq-id" => build.id
      })

      # build → nuevo → test-step: el step nuevo nació en medio.
      steps = Workflows.list_steps(workflow)
      new_step = Enum.find(steps, &(&1.title == "Nuevo paso"))

      assert new_step != nil
      assert build.id in Contracts.prerequisite_ids(Workflows.get_step!(new_step.id))
      assert new_step.id in Contracts.prerequisite_ids(Workflows.get_step!(test_step.id))
    end

    test "link_step_between places an EXISTING step in the middle of the edge", %{
      conn: conn,
      ws: ws,
      workflow: workflow
    } do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/workflows/#{workflow.slug}")
      steps = Workflows.list_steps(workflow)
      build = Enum.find(steps, &(&1.slug == "build"))
      deploy = Enum.find(steps, &(&1.slug == "deploy"))
      test_step = Enum.find(steps, &(&1.slug == "test-step"))

      # build → test-step ya existe; deploy queda entre ambos.
      view
      |> element("#wfe-canvas")
      |> render_hook("link_step_between", %{
        "dependent-id" => test_step.id,
        "prereq-id" => build.id,
        "middle-id" => deploy.id
      })

      assert build.id in Contracts.prerequisite_ids(Workflows.get_step!(deploy.id))
      assert deploy.id in Contracts.prerequisite_ids(Workflows.get_step!(test_step.id))
    end

    test "repack_layout clears every saved position", %{conn: conn, ws: ws, workflow: workflow} do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/workflows/#{workflow.slug}")
      build = Enum.find(Workflows.list_steps(workflow), &(&1.slug == "build"))
      deploy = Enum.find(Workflows.list_steps(workflow), &(&1.slug == "deploy"))

      view
      |> element("#wfe-canvas")
      |> render_hook("move_step", %{"step-id" => build.id, "x" => "500", "y" => "400"})

      view
      |> element("#wfe-canvas")
      |> render_hook("move_step", %{"step-id" => deploy.id, "x" => "516", "y" => "416"})

      assert Enum.any?(Workflows.list_steps(workflow), &(&1.pos_x != nil))

      view
      |> element("#wfe-canvas")
      |> render_hook("repack_layout", %{})

      assert Enum.all?(Workflows.list_steps(workflow), &is_nil(&1.pos_x))
    end

    test "new_step_at patches the URL with pos params; save_step births the step there", %{
      conn: conn,
      ws: ws,
      workflow: workflow
    } do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/workflows/#{workflow.slug}")

      view
      |> element("#wfe-canvas")
      |> render_hook("new_step_at", %{"x" => "300", "y" => "240"})

      assert_patch(view, 300)

      view
      |> form("#step-modal-form", step: %{"title" => "Creado en canvas"})
      |> render_submit()

      assert_patch(view, 300)

      # Auto-managed slug: derived from the title.
      created = Enum.find(Workflows.list_steps(workflow), &(&1.slug == "creado-en-canvas"))
      assert created.pos_x == 190 and created.pos_y == 192
    end

    test "renders edge ✕ buttons and always-present ports", %{
      conn: conn,
      ws: ws,
      workflow: workflow
    } do
      {:ok, _view, html} = live(conn, ~p"/#{ws.slug}/workflows/#{workflow.slug}")

      assert html =~ "data-testid=\"edge-remove\""
      assert html =~ "data-testid=\"port-in\""
      assert html =~ "data-testid=\"port-out\""
    end

    test "cards are drag-first: no phx-click on the node, a pencil per step", %{
      conn: conn,
      ws: ws,
      workflow: workflow
    } do
      {:ok, _view, html} = live(conn, ~p"/#{ws.slug}/workflows/#{workflow.slug}")

      # The card itself no longer carries the edit click (drag owns it).
      refute html =~ ~s(data-testid="step-node" phx-click)

      # One pencil per step, each wired to the edit modal.
      steps = Workflows.list_steps(workflow)
      assert length(Regex.scan(~r/data-testid="step-edit"/, html)) == length(steps)

      for step <- steps do
        assert html =~ ~s(phx-value-step-id="#{step.id}")
      end
    end
  end

  test "graph geometry: positions map drives edges/ports (levels layout default)" do
    alias DranWeb.WorkflowsLive

    levels = [["p1"], ["d1"]]
    positions = WorkflowsLive.layout_positions(levels)
    passed = MapSet.new(["p1"])

    # relation tuple as stored in the DB: {dependent, prereq}
    [{_dep, edge}] = WorkflowsLive.graph_edges([{"d1", "p1"}], positions, passed)

    # flows left to right: starts at the prereq output (right edge)
    {px, _py} = WorkflowsLive.node_position(positions, "p1")
    {dx, _dy} = WorkflowsLive.node_position(positions, "d1")
    assert edge.x1 == px + WorkflowsLive.node_w()
    assert edge.x2 == dx
    assert edge.x1 < edge.x2
    assert edge.done

    # without a passed run the edge stays pending
    [{_dep, pending_edge}] = WorkflowsLive.graph_edges([{"d1", "p1"}], positions, MapSet.new())
    refute pending_edge.done

    # ports agree: prereq owns the output dot, dependent owns the input dot
    ports = WorkflowsLive.graph_ports([{"d1", edge}], positions)
    assert ports["p1"].out.x == edge.x1
    assert ports["d1"].in.x == edge.x2

    # free layout: pos_x/pos_y win over levels for every step (all-or-nothing)
    free = [
      %{id: "p1", pos_x: 500, pos_y: 40},
      %{id: "d1", pos_x: 500, pos_y: 200}
    ]

    free_positions = WorkflowsLive.step_positions(free, levels)
    assert free_positions["p1"] == {500, 40}
    assert free_positions["d1"] == {500, 200}

    # partial positions → full levels fallback (no jumps)
    partial = [hd(free), %{id: "d1", pos_x: nil, pos_y: nil}]
    assert WorkflowsLive.step_positions(partial, levels) == positions
  end
end
