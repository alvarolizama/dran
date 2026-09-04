defmodule DranWeb.API.ExecutionControllerTest do
  use DranWeb.ConnCase, async: false

  alias Dran.{Accounts, Contracts, Executions, Knowledge, Repo, Workflows}

  setup do
    unique = System.unique_integer([:positive])

    {:ok, owner} =
      Accounts.create_user(%{
        email: "owner-#{unique}@example.com",
        name: "Owner",
        is_owner: true
      })

    {:ok, workspace} =
      Knowledge.create_workspace(%{
        name: "Exec API #{unique}",
        slug: "exec-api-#{unique}"
      })

    {:ok, key} =
      Accounts.create_api_key(%{
        name: "agent-exec-#{unique}",
        workspace_ids: [{workspace.id, "write"}],
        created_by_user_id: owner.id
      })

    key = Repo.preload(key, :actor)

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("accept", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{key.token}")

    {:ok, conn: conn, workspace: workspace, key: key}
  end

  describe "POST /api/workflows/:workflow_id/sessions" do
    test "opens a session with runs upfront and stamps the acting actor", %{
      conn: conn,
      workspace: workspace,
      key: key
    } do
      {workflow, [step1, step2]} = new_workflow(workspace, ["Step A", "Step B"])

      conn =
        post(conn, "/api/workflows/#{workflow.id}/sessions", %{
          label: "release 1",
          context: %{"trigger" => "manual"}
        })

      assert %{"data" => data} = json_response(conn, 201)
      assert data["status"] == "in_flight"
      assert data["workflow_id"] == workflow.id
      assert data["workspace_id"] == workspace.id
      assert data["label"] == "release 1"
      assert data["context"] == %{"trigger" => "manual"}
      assert data["actor_id"] == key.actor.id

      run_step_ids = data["runs"] |> Enum.map(& &1["step_id"]) |> MapSet.new()
      assert run_step_ids == MapSet.new([step1.id, step2.id])
      assert Enum.all?(data["runs"], &(&1["status"] == "pending"))
      assert Enum.all?(data["runs"], &(&1["attempt"] == 1))
      assert data["progress"]["pending"] == 2
    end

    test "refuses a workflow with no steps (422)", %{conn: conn, workspace: workspace} do
      {:ok, workflow} =
        Workflows.create_workflow(%{
          "workspace_id" => workspace.id,
          "title" => "Empty",
          "slug" => "empty-#{System.unique_integer([:positive])}"
        })

      conn = post(conn, "/api/workflows/#{workflow.id}/sessions", %{})

      assert %{"errors" => %{"detail" => "workflow has no steps"}} = json_response(conn, 422)
    end

    test "403 for unknown or malformed workflow id (no existence leak)", %{conn: conn} do
      # require_write_access cannot resolve a workspace from an unknown id →
      # 403 (same SEC-002 convention as /api/todos/:id).
      conn = post(conn, "/api/workflows/#{Ecto.UUID.generate()}/sessions", %{})
      assert %{"errors" => _} = json_response(conn, 403)

      conn = post(conn, "/api/workflows/not-a-uuid/sessions", %{})
      assert %{"errors" => _} = json_response(conn, 403)
    end
  end

  describe "GET /api/pending_runs" do
    test "returns only ready pending runs, in topological order", %{
      conn: conn,
      workspace: workspace
    } do
      {workflow, [a, b]} = new_workflow(workspace, ["A", "B"])
      {:ok, _} = Contracts.add_dependency(b, a)
      {:ok, session} = Executions.open_session(workflow)

      # Both runs exist but B is blocked by A → only A is offered.
      conn = get(conn, "/api/pending_runs?workspace=#{workspace.slug}")
      assert %{"data" => [run]} = json_response(conn, 200)
      assert run["step_id"] == a.id
      assert run["session_id"] == session.id
      assert run["step_title"] == "A"
      assert run["workflow_id"] == workflow.id

      # Complete A through the API → B becomes ready.
      a_run = Executions.list_runs(session) |> Enum.find(&(&1.step_id == a.id))

      conn =
        conn
        |> post("/api/runs/#{a_run.id}/start")
        |> post("/api/runs/#{a_run.id}/close", %{
          status: "passed",
          outcome: "done",
          gate_results: %{"g1" => %{"status" => "ok"}}
        })

      assert json_response(conn, 200)

      conn = get(conn, "/api/pending_runs?workspace=#{workspace.slug}")
      assert %{"data" => [run]} = json_response(conn, 200)
      assert run["step_id"] == b.id
    end

    test "filters by workflow", %{conn: conn, workspace: workspace} do
      {workflow_a, _} = new_workflow(workspace, ["A1"])
      {workflow_b, [b]} = new_workflow(workspace, ["B1"])
      {:ok, _} = Executions.open_session(workflow_a)
      {:ok, _} = Executions.open_session(workflow_b)

      conn = get(conn, "/api/pending_runs?workspace=#{workspace.slug}&workflow=#{workflow_a.id}")
      assert %{"data" => runs} = json_response(conn, 200)
      assert length(runs) == 1
      refute Enum.any?(runs, &(&1["step_id"] == b.id))
    end

    test "400 without workspace, 404 for unknown workspace", %{conn: conn} do
      conn = get(conn, "/api/pending_runs")
      assert %{"errors" => _} = json_response(conn, 400)

      conn = get(conn, "/api/pending_runs?workspace=no-such-workspace")
      assert %{"errors" => _} = json_response(conn, 404)
    end
  end

  describe "POST /api/runs/:id/start" do
    test "claims a pending run and refuses a double claim (409)", %{
      conn: conn,
      workspace: workspace
    } do
      {workflow, [_step]} = new_workflow(workspace, ["Single"])
      {:ok, session} = Executions.open_session(workflow)
      [run] = Executions.list_runs(session)

      conn = post(conn, "/api/runs/#{run.id}/start")
      assert %{"data" => data} = json_response(conn, 200)
      assert data["status"] == "in_flight"

      conn = post(conn, "/api/runs/#{run.id}/start")
      assert %{"errors" => %{"detail" => detail}} = json_response(conn, 409)
      assert detail =~ "in_flight"
    end

    test "403 for unknown run id (no existence leak)", %{conn: conn} do
      # require_write_access cannot resolve a workspace from an unknown id →
      # 403 (same SEC-002 convention as /api/todos/:id).
      conn = post(conn, "/api/runs/#{Ecto.UUID.generate()}/start")
      assert %{"errors" => _} = json_response(conn, 403)
    end
  end

  describe "PUT /api/runs/:id/progress" do
    test "overwrites progress on an in_flight run", %{conn: conn, workspace: workspace} do
      {workflow, [_step]} = new_workflow(workspace, ["Single"])
      {:ok, session} = Executions.open_session(workflow)
      [run] = Executions.list_runs(session)

      conn = post(conn, "/api/runs/#{run.id}/start")
      assert json_response(conn, 200)

      conn =
        put(conn, "/api/runs/#{run.id}/progress", %{
          progress: %{"phase" => "implementing", "gates" => %{"compile" => "ok"}}
        })

      assert %{"data" => data} = json_response(conn, 200)
      assert data["progress"] == %{"phase" => "implementing", "gates" => %{"compile" => "ok"}}
      assert data["status"] == "in_flight"
    end

    test "rejects non-map progress (400) and a pending run (409)", %{
      conn: conn,
      workspace: workspace
    } do
      {workflow, [_step]} = new_workflow(workspace, ["Single"])
      {:ok, session} = Executions.open_session(workflow)
      [run] = Executions.list_runs(session)

      conn = put(conn, "/api/runs/#{run.id}/progress", %{progress: "not-a-map"})
      assert %{"errors" => _} = json_response(conn, 400)

      conn = put(conn, "/api/runs/#{run.id}/progress", %{progress: %{"phase" => "x"}})
      assert %{"errors" => %{"detail" => "run is not in_flight"}} = json_response(conn, 409)
    end
  end

  describe "POST /api/runs/:id/close" do
    test "closes the run with a result and auto-closes the session on the last run", %{
      conn: conn,
      workspace: workspace
    } do
      {workflow, [_step]} = new_workflow(workspace, ["Single"])
      {:ok, session} = Executions.open_session(workflow)
      [run] = Executions.list_runs(session)

      conn = post(conn, "/api/runs/#{run.id}/start")
      assert json_response(conn, 200)

      conn =
        post(conn, "/api/runs/#{run.id}/close", %{
          status: "passed",
          outcome: "all gates green",
          gate_results: %{"g1" => %{"status" => "ok"}},
          checkpoints: %{"P1" => "verified"}
        })

      assert %{"data" => data, "session" => session_data} = json_response(conn, 200)
      assert data["status"] == "passed"
      assert data["outcome"] == "all gates green"
      assert data["gate_results"] == %{"g1" => %{"status" => "ok"}}
      assert data["checkpoints"] == %{"P1" => "verified"}
      # Last open run → session closes as passed.
      assert session_data["status"] == "passed"
      assert session_data["progress"]["passed"] == 1
      refute is_nil(session_data["finished_at"])
    end

    test "409 for an already-closed run, 422 for an invalid status", %{
      conn: conn,
      workspace: workspace
    } do
      {workflow, [_step]} = new_workflow(workspace, ["Single"])
      {:ok, session} = Executions.open_session(workflow)
      [run] = Executions.list_runs(session)

      # Invalid status never claims: 422.
      conn = post(conn, "/api/runs/#{run.id}/close", %{status: "maybe"})
      assert %{"errors" => _} = json_response(conn, 422)

      conn = post(conn, "/api/runs/#{run.id}/start")
      assert json_response(conn, 200)

      conn = post(conn, "/api/runs/#{run.id}/close", %{status: "passed"})
      assert json_response(conn, 200)

      # Second close: no longer in_flight → 409.
      conn = post(conn, "/api/runs/#{run.id}/close", %{status: "passed"})
      assert %{"errors" => %{"detail" => "run is not in_flight"}} = json_response(conn, 409)
    end
  end

  describe "POST /api/runs/:id/retry" do
    test "creates a new pending attempt of a failed run and reopens a failed session", %{
      conn: conn,
      workspace: workspace
    } do
      {workflow, [_step]} = new_workflow(workspace, ["Single"])
      {:ok, session} = Executions.open_session(workflow)
      [run] = Executions.list_runs(session)

      conn = post(conn, "/api/runs/#{run.id}/start")
      assert json_response(conn, 200)

      conn = post(conn, "/api/runs/#{run.id}/close", %{status: "failed", outcome: "boom"})
      assert %{"session" => %{"status" => "failed"}} = json_response(conn, 200)

      conn = post(conn, "/api/runs/#{run.id}/retry")
      assert %{"data" => data, "session" => session_data} = json_response(conn, 201)
      assert data["attempt"] == 2
      assert data["status"] == "pending"
      assert session_data["status"] == "in_flight"
    end

    test "409 when the run is not failed", %{conn: conn, workspace: workspace} do
      {workflow, [_step]} = new_workflow(workspace, ["Single"])
      {:ok, session} = Executions.open_session(workflow)
      [run] = Executions.list_runs(session)

      conn = post(conn, "/api/runs/#{run.id}/retry")
      assert %{"errors" => _} = json_response(conn, 409)
    end
  end

  describe "GET /api/workflow_sessions/:id" do
    test "returns session state with runs and progress counts", %{
      conn: conn,
      workspace: workspace
    } do
      {workflow, _} = new_workflow(workspace, ["A", "B"])
      {:ok, session} = Executions.open_session(workflow, label: "inspect me")

      conn = get(conn, "/api/workflow_sessions/#{session.id}")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["id"] == session.id
      assert data["label"] == "inspect me"
      assert data["progress"]["total"] == 2
      assert data["progress"]["pending"] == 2
      assert length(data["runs"]) == 2
      assert data["snapshot"]["steps"] |> length() == 2
    end

    test "404 for unknown session", %{conn: conn} do
      conn = get(conn, "/api/workflow_sessions/#{Ecto.UUID.generate()}")
      assert %{"errors" => _} = json_response(conn, 404)
    end
  end

  describe "auth" do
    test "401 without a Bearer token", %{workspace: workspace} do
      {workflow, _} = new_workflow(workspace, ["A"])

      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("accept", "application/json")
        |> post("/api/workflows/#{workflow.id}/sessions", %{})

      assert %{"errors" => _} = json_response(conn, 401)
    end

    test "403 for a read-only API key on a write endpoint", %{
      workspace: workspace,
      key: key
    } do
      {:ok, read_key} =
        Accounts.create_api_key(%{
          name: "agent-read-#{System.unique_integer([:positive])}",
          workspace_ids: [{workspace.id, "read"}],
          created_by_user_id: key.created_by_user_id
        })

      {workflow, _} = new_workflow(workspace, ["A"])

      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("accept", "application/json")
        |> Plug.Conn.put_req_header("authorization", "Bearer #{read_key.token}")
        |> post("/api/workflows/#{workflow.id}/sessions", %{})

      assert %{"errors" => _} = json_response(conn, 403)
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Helpers
  # ──────────────────────────────────────────────────────────────────────────

  defp new_workflow(workspace, titles) do
    {:ok, workflow} =
      Workflows.create_workflow(%{
        "workspace_id" => workspace.id,
        "title" => "W #{System.unique_integer([:positive])}",
        "slug" => "w-#{System.unique_integer([:positive])}"
      })

    steps =
      Enum.map(titles, fn title ->
        {:ok, step} =
          Workflows.create_step(workflow, %{
            "title" => title,
            "slug" => "step-#{System.unique_integer([:positive])}"
          })

        step
      end)

    {workflow, steps}
  end
end
