defmodule DranWeb.API.ExecutionController do
  @moduledoc """
  F3 REST API for workflow executions — the agent loop over
  `Dran.Executions`:

      1. POST /api/workflows/:workflow_id/sessions   → open a session
         (runs are created upfront, one `pending` per step)
      2. GET  /api/pending_runs?workspace=...        → pull ready runs
      3. POST /api/runs/:id/start                    → claim pending→in_flight
      4. PUT  /api/runs/:id/progress                 → report phase progress
      5. POST /api/runs/:id/close                    → report the outcome
         (closing the last open run auto-closes the session)
      + POST /api/runs/:id/retry                     → new attempt of a failed run
      + GET  /api/workflow_sessions/:id              → inspect session + runs

  Attribution follows the actor model: sessions, claims and progress writes
  are stamped with the authenticated identity's actor id
  (`Dran.Auth.resolve_acting_actor/1`) — never client-settable.

  Read routes live in the `:api_auth` scope; mutating routes require API-key
  write access (`:require_write_access`, resolved from the run/workflow's
  workspace by the router).
  """

  use DranWeb, :controller

  alias Dran.Auth
  alias Dran.Executions
  alias Dran.Repo
  alias Dran.Run
  alias Dran.WorkflowSession

  @doc "POST /api/workflows/:workflow_id/sessions — open a session (runs upfront)."
  def open(conn, %{"workflow_id" => workflow_id} = params) do
    with {:ok, workflow} <- fetch_workflow(workflow_id) do
      opts =
        []
        |> maybe_put(:label, label_param(params))
        |> maybe_put(:context, context_param(params))
        |> Keyword.put(:actor_id, acting_actor_id(conn))

      case Executions.open_session(workflow, opts) do
        {:ok, session} ->
          conn
          |> put_status(:created)
          |> json(%{data: render_session(session, session.runs)})

        {:error, reason} ->
          respond_error(conn, reason)
      end
    end
  end

  @doc "GET /api/pending_runs?workspace=…&workflow=… — the agent pull endpoint."
  def pending(conn, params) do
    case resolve_workspace(params["workspace"]) do
      nil ->
        if blank?(params["workspace"]) do
          conn
          |> put_status(:bad_request)
          |> json(%{errors: %{detail: "workspace query param is required"}})
        else
          conn
          |> put_status(:not_found)
          |> json(%{errors: %{detail: "workspace not found"}})
        end

      workspace_id ->
        # UUID-guard the workflow param (review finding #6): a garbage
        # value would hit the query as ^workflow_id and raise CastError →
        # 500. Everything else in this controller UUID-casts — the query
        # param must too.
        {bad_workflow, workflow_param} =
          case params["workflow"] do
            nil ->
              {false, nil}

            value ->
              case Ecto.UUID.cast(value) do
                {:ok, uuid} -> {false, uuid}
                :error -> {true, value}
              end
          end

        if bad_workflow do
          conn
          |> put_status(:bad_request)
          |> json(%{errors: %{detail: "workflow must be a UUID"}})
        else
          # Ownership baked rule: the pull answers "what is available to
          # ME" — owned sessions only surface for their owner; unowned
          # sessions stay in the open queue for everyone.
          opts =
            []
            |> maybe_put(:workflow_id, workflow_param)
            |> Keyword.put(:actor_id, acting_actor_id(conn))

          runs =
            workspace_id
            |> Executions.list_pending_runs(opts)
            |> Repo.preload(step: [], session: [])

          json(conn, %{data: Enum.map(runs, &render_pending_run/1)})
        end
    end
  end

  @doc "GET /api/workflow_sessions/:id — session state, runs and progress counts."
  def show_session(conn, %{"id" => id}) do
    case fetch_workflow_session(id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{errors: %{detail: "session not found"}})

      session ->
        # Cross-workspace read guard (review finding #3): read routes only
        # pass :api_auth — without a check a key scoped to workspace A
        # could read any workspace's session (snapshot/contracts/gates) by
        # enumerating UUIDs. Writes are already guarded by
        # require_write_access resolving the workspace from the run.
        if DranWeb.ResourceAuthorization.authorize(
             conn.assigns[:user],
             :read,
             session.workspace_id
           ) == :ok do
          runs = Executions.list_runs(session)
          json(conn, %{data: render_session(session, runs)})
        else
          conn
          |> put_status(:not_found)
          |> json(%{errors: %{detail: "session not found"}})
        end
    end
  end

  @doc "POST /api/runs/:id/start — claim a pending run (pending → in_flight)."
  def start(conn, %{"id" => id}) do
    case fetch_run(id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{errors: %{detail: "run not found"}})

      run ->
        case Executions.start_run(run, actor_id: acting_actor_id(conn)) do
          {:ok, claimed} ->
            json(conn, %{data: render_run(claimed)})

          {:error, reason} ->
            respond_error(conn, reason)
        end
    end
  end

  @doc "PUT /api/runs/:id/progress — overwrite the phase-level progress map."
  def progress(conn, %{"id" => id} = params) do
    progress = params["progress"]

    cond do
      not is_map(progress) ->
        conn
        |> put_status(:bad_request)
        |> json(%{errors: %{detail: "progress must be an object"}})

      true ->
        case Executions.update_progress(id, progress, actor_id: acting_actor_id(conn)) do
          {:ok, run} ->
            json(conn, %{data: render_run(run)})

          {:error, reason} ->
            respond_error(conn, reason)
        end
    end
  end

  @doc """
  POST /api/runs/:id/close — report the terminal result: `status` (passed |
  failed | skipped, required), optional `outcome`, `gate_results`,
  `checkpoints`.
  """
  def close(conn, %{"id" => id} = params) do
    case fetch_run(id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{errors: %{detail: "run not found"}})

      run ->
        attrs =
          params
          |> Map.take(["status", "outcome", "gate_results", "checkpoints"])
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)
          |> Map.new()

        case Executions.close_run(run, attrs, actor_id: acting_actor_id(conn)) do
          {:ok, closed} ->
            session = Repo.get!(WorkflowSession, closed.session_id)

            json(conn, %{
              data: render_run(closed),
              session: render_session(session, Executions.list_runs(session))
            })

          {:error, reason} ->
            respond_error(conn, reason)
        end
    end
  end

  @doc "POST /api/runs/:id/retry — new pending attempt of a failed run."
  def retry(conn, %{"id" => id}) do
    case fetch_run(id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{errors: %{detail: "run not found"}})

      run ->
        case Executions.retry_run(run) do
          {:ok, new_run} ->
            session = Repo.get!(WorkflowSession, new_run.session_id)

            conn
            |> put_status(:created)
            |> json(%{
              data: render_run(new_run),
              session: render_session(session, Executions.list_runs(session))
            })

          {:error, reason} ->
            respond_error(conn, reason)
        end
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Fetch helpers (UUID-safe: garbage ids 404, never raise)
  # ──────────────────────────────────────────────────────────────────────────

  defp fetch_workflow(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        case Repo.get(Dran.Workflow, uuid) do
          nil -> {:error, :workflow_not_found}
          workflow -> {:ok, workflow}
        end

      :error ->
        {:error, :workflow_not_found}
    end
  end

  defp fetch_run(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(Run, uuid)
      :error -> nil
    end
  end

  defp fetch_workflow_session(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(WorkflowSession, uuid)
      :error -> nil
    end
  end

  # Slug or UUID — same resolution as MemoryController.
  defp resolve_workspace(nil), do: nil

  defp resolve_workspace(value) do
    case Dran.Knowledge.get_workspace_by_slug(value) do
      %{id: id} ->
        id

      nil ->
        case Ecto.UUID.cast(value) do
          {:ok, uuid} ->
            case Repo.get(Dran.Workspace, uuid) do
              %{id: id} -> id
              _ -> nil
            end

          :error ->
            nil
        end
    end
  end

  defp acting_actor_id(conn), do: Auth.resolve_acting_actor(conn.assigns[:user])

  defp label_param(params) do
    if is_binary(params["label"]), do: params["label"], else: nil
  end

  defp context_param(params) do
    if is_map(params["context"]), do: params["context"], else: %{}
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  # ──────────────────────────────────────────────────────────────────────────
  # Error mapping — context reasons → HTTP status + detail
  # ──────────────────────────────────────────────────────────────────────────

  defp respond_error(conn, reason) do
    {status, detail} = translate_error(reason)

    conn
    |> put_status(status)
    |> json(%{errors: %{detail: detail}})
  end

  defp translate_error(:workflow_not_found), do: {404, "workflow not found"}
  defp translate_error(:workflow_has_no_steps), do: {422, "workflow has no steps"}
  defp translate_error(:workflow_archived), do: {422, "workflow is archived"}

  defp translate_error(:workflow_already_ran),
    do: {409, "one_shot workflow already has a session"}

  defp translate_error(:workflow_changed), do: {409, "workflow changed while opening — retry"}
  defp translate_error(:run_not_found), do: {404, "run not found"}
  defp translate_error(:not_in_flight), do: {409, "run is not in_flight"}
  defp translate_error(:session_closed), do: {409, "session is closed"}
  defp translate_error(:not_run_owner), do: {403, "run belongs to another actor"}

  defp translate_error(:invalid_status),
    do: {422, "status must be one of: passed, failed, skipped"}

  defp translate_error({:wrong_status, actual, expected}),
    do: {409, "run status is #{actual}, expected #{expected}"}

  defp translate_error({:superseded, status}),
    do: {409, "run is superseded by a newer attempt (latest: #{status})"}

  defp translate_error({:session_not_retryable, status}),
    do: {409, "session is #{status} and cannot be reopened"}

  defp translate_error(_reason), do: {500, "unexpected error"}

  # ──────────────────────────────────────────────────────────────────────────
  # Renderers — explicit field lists (no Jason.Encoder derive on schemas)
  # ──────────────────────────────────────────────────────────────────────────

  defp render_session(%WorkflowSession{} = session, runs) do
    %{
      id: session.id,
      workflow_id: session.workflow_id,
      goal_id: session.goal_id,
      workspace_id: session.workspace_id,
      status: session.status,
      label: session.label,
      context: session.context,
      snapshot: session.snapshot,
      started_at: session.started_at,
      finished_at: session.finished_at,
      actor_id: session.actor_id,
      inserted_at: session.inserted_at,
      updated_at: session.updated_at,
      progress: Executions.session_progress(session),
      runs: Enum.map(runs, &render_run/1)
    }
  end

  defp render_run(%Run{} = run) do
    %{
      id: run.id,
      session_id: run.session_id,
      step_id: run.step_id,
      workspace_id: run.workspace_id,
      status: run.status,
      attempt: run.attempt,
      outcome: run.outcome,
      gate_results: run.gate_results,
      checkpoints: run.checkpoints,
      progress: run.progress,
      contract_version: run.contract_version,
      actor_id: run.actor_id,
      inserted_at: run.inserted_at,
      updated_at: run.updated_at
    }
  end

  defp render_pending_run(%Run{} = run) do
    session = run.session
    step = run.step

    run
    |> render_run()
    |> Map.merge(%{
      workflow_id: session.workflow_id,
      session_label: session.label,
      step_title: step.title,
      step_position: step.position
    })
  end
end
