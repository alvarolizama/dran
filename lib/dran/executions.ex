defmodule Dran.Executions do
  @moduledoc """
  The Executions context — session + run tracking for WORKFLOWS.

  ## The model (execution layer, 2026-09)

  - `workflow_sessions` — one pass over a workflow, frozen into
    `snapshot` at open time (`%{\"steps\" => [...], \"edges\" =>
    [[from, to]]}`). An evergreen workflow can have N sessions, even
    simultaneous. The goal link (`goal_id`) is optional — denormalized
    from `workflow.goal_id` at open time, display only.
  - `runs` — one execution attempt of a STEP within a session, the ONLY
    runtime. Runs are created upfront (all `pending`) when the session
    opens, keyed by `(session_id, step_id, attempt)`. Retries are new
    runs with `attempt: n + 1`. **No task is ever spawned** — the manual
    layer (board) and the execution layer never mix.
  - `progress` (jsonb) — phase-level progress reported by the agent via
    `update_progress/3`: overwrite semantics (the history lives in
    `gate_results` at close, decisión ?02).

  ## Rules baked into this context

  - `run_ready?/1` — prerequisites are resolved from the session's
    FROZEN snapshot edges (NOT live relations): a run is ready when
    every direct prerequisite of its step has a `passed` run IN THE
    SESSION. Deliberately session-scoped: simultaneous sessions never
    block each other (P6).
  - `start_run/1` — conditional claim (`WHERE status = 'pending'`):
    exactly one of two concurrent claimants wins; the loser gets
    `{:error, {:wrong_status, actual, \"pending\"}}` (decisión ?07).
  - `close_run/2` — persists `outcome` + `gate_results` (+ optional
    `checkpoints`), conditional on `in_flight`. Closing the last open
    run closes the session (`passed` when every step's LATEST attempt
    is passed/skipped, `failed` otherwise) and stamps `finished_at`.
  - `update_progress/3` — overwrite of `progress` on an `in_flight` run;
    never changes status (P4).
  - `abort_session/1` — the manual escape hatch: open runs → `skipped`,
    session → `aborted` + `finished_at`.
  - `gate_results`, `checkpoints` and `progress` are DATA (the
    executor's report), never enforced server-side.
  """

  import Ecto.Query, warn: false

  alias Dran.Repo
  alias Dran.WorkflowSession
  alias Dran.Run

  @doc """
  Open a session for a WORKFLOW: creates the `in_flight` session plus
  `pending` runs (attempt 1) for EVERY step of the workflow, and freezes
  the `snapshot`.

  `goal_id` is denormalized from `workflow.goal_id` (optional link). The
  snapshot is `%{\"steps\" => [%{\"id\", \"title\", \"contract\"}],
  \"edges\" => [[from_id, to_id]]}` — the step→step `depends_on` edges at
  open time. Each run freezes `step.meta[\"contract\"]` into
  `contract_version` (nil when the step has no contract).

  Refuses a workflow with no steps (`{:error, :workflow_has_no_steps}`)
  or an archived workflow (`{:error, :workflow_archived}`). The session
  and all its runs are created in a single transaction.

  Returns `{:ok, session}` (with `:runs` preloaded) or `{:error, reason}`.
  """
  def open_session(%Dran.Workflow{} = workflow, opts \\ []) do
    workspace_id = workflow.workspace_id
    label = Keyword.get(opts, :label)
    context = Keyword.get(opts, :context, %{})
    actor_id = Keyword.get(opts, :actor_id)
    started_at = DateTime.utc_now()

    with :ok <- ensure_workflow_runnable(workflow),
         :ok <- ensure_workflow_has_steps(workflow) do
      Repo.transaction(fn ->
        steps = Dran.Workflows.list_steps(workflow)
        snapshot = workflow_snapshot(steps)

        session =
          %WorkflowSession{}
          |> WorkflowSession.changeset(%{
            workflow_id: workflow.id,
            goal_id: workflow.goal_id,
            workspace_id: workspace_id,
            snapshot: snapshot,
            label: label,
            context: context,
            status: "in_flight",
            actor_id: actor_id,
            started_at: started_at
          })
          |> Repo.insert!()

        Enum.each(steps, fn step ->
          %Run{}
          |> Run.changeset(%{
            session_id: session.id,
            step_id: step.id,
            workspace_id: workspace_id,
            contract_version: step.meta["contract"],
            status: "pending",
            attempt: 1,
            actor_id: actor_id
          })
          |> Repo.insert!()
        end)

        session
        |> Repo.preload(:runs)
      end)
      |> case do
        {:ok, session} ->
          broadcast_session_change(session, :opened)
          {:ok, session}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "Get a session by id, raises if missing."
  def get_session!(id), do: Repo.get!(WorkflowSession, id)

  @doc """
  List sessions of a workflow, most recent first.
  """
  def list_sessions(%Dran.Workflow{} = workflow) do
    Repo.all(
      from s in WorkflowSession,
        where: s.workflow_id == ^workflow.id,
        order_by: [desc: s.inserted_at]
    )
  end

  @doc "List the runs of a session, oldest first (attempt order)."
  def list_runs(%WorkflowSession{} = session) do
    Repo.all(
      from r in Run,
        where: r.session_id == ^session.id,
        order_by: [asc: r.attempt, asc: r.inserted_at]
    )
  end

  @doc """
  Pending runs available to an actor, optionally filtered by workflow —
  the agent pull endpoint (F3).

  A pending run is offered when it is READY (prerequisites passed in its
  session) and its session is open. Order: oldest session first.
  """
  def list_pending_runs(workspace_id, opts \\ []) do
    workflow_id = Keyword.get(opts, :workflow_id)
    actor_id = Keyword.get(opts, :actor_id)

    base =
      from r in Run,
        join: s in WorkflowSession,
        on: s.id == r.session_id,
        where:
          r.workspace_id == ^workspace_id and
            r.status == "pending" and
            s.status == "in_flight",
        order_by: [asc: r.inserted_at]

    base =
      if workflow_id do
        from [r, s] in base, where: s.workflow_id == ^workflow_id
      else
        base
      end

    base =
      if actor_id do
        from [r, s] in base, where: r.actor_id == ^actor_id
      else
        base
      end

    Repo.all(base)
    |> Enum.filter(&run_ready?/1)
  end

  @doc """
  Is the run ready to execute?

  Prerequisites are resolved from the session's FROZEN `snapshot` edges —
  NOT from live step→step relations. The snapshot is the topology that
  pass was opened with: editing the workflow mid-session
  (adding/removing edges) never re-sequences an open session.

  A run is ready when every direct prerequisite of its step (per the
  snapshot) has a `passed` run IN THE SESSION of this run. No
  prerequisites → ready. Deliberately session-scoped: two simultaneous
  sessions over the same workflow never block each other (P6).
  """
  def run_ready?(%Run{} = run) do
    prerequisite_ids = snapshot_prerequisite_ids(run)

    prerequisite_ids == [] or prereqs_satisfied?(run.session_id, prerequisite_ids)
  end

  # Direct prerequisites of the run's step per the FROZEN snapshot edges.
  # Snapshot edges are [from=dependiente, to=prereq] pairs — a prereq of X
  # is any edge whose first element is X.
  defp snapshot_prerequisite_ids(%Run{} = run) do
    session =
      case run.session do
        %WorkflowSession{} = loaded -> loaded
        _not_loaded -> Repo.get!(WorkflowSession, run.session_id)
      end

    session.snapshot
    |> Map.get("edges", [])
    |> Enum.filter(fn [from, _to] -> from == run.step_id end)
    |> Enum.map(fn [_from, to] -> to end)
  end

  # ALL prerequisites must be satisfied, each by a passed run IN THIS
  # SESSION. A passed run is always the latest attempt of its step in the
  # session (retries only spawn from failed runs), so any passed run of
  # a prerequisite counts.
  defp prereqs_satisfied?(session_id, prerequisite_step_ids) do
    statuses =
      Repo.all(
        from r in Run,
          where: r.session_id == ^session_id and r.step_id in ^prerequisite_step_ids,
          select: {r.step_id, r.status}
      )

    passed_steps =
      statuses
      |> Enum.filter(fn {_step_id, status} -> status == "passed" end)
      |> Enum.map(&elem(&1, 0))
      |> MapSet.new()

    steps_with_runs = statuses |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    Enum.all?(prerequisite_step_ids, fn step_id ->
      cond do
        MapSet.member?(passed_steps, step_id) -> true
        MapSet.member?(steps_with_runs, step_id) -> false
        # Cross-workflow edge: no run in this session — never satisfied.
        true -> false
      end
    end)
  end

  @doc """
  Move a run from `pending` to `in_flight` (the executor claims it).

  The claim is a conditional UPDATE (`WHERE status = 'pending'`), so two
  concurrent agents can never both claim the same run — exactly one
  wins, the loser gets `{:error, {:wrong_status, actual, \"pending\"}}`
  (decisión ?07). Refuses runs of a closed session. `opts`:
  `:actor_id` stamps the claimer.
  """
  def start_run(%Run{} = run, opts \\ []) do
    Repo.transaction(fn ->
      with :ok <- assert_session_open(run),
           {:ok, claimed} <- claim_pending(run, opts) do
        {:ok, claimed}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {:ok, updated}} ->
        broadcast_run_change(updated, :started)
        {:ok, updated}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Close a run with a result.

  `attrs`: `status` (one of `passed | failed | skipped` — required),
  `outcome` (summary), `gate_results` (map, per-gate report),
  `checkpoints` (map of ledger entries).

  The close is conditional on `in_flight`: two executors holding the
  same struct cannot both close — exactly one wins. Closing the last
  open run (`pending | in_flight`) of the session closes the session:
  `passed` when every step's LATEST attempt is `passed`/`skipped`,
  `failed` otherwise, `finished_at` stamped now.

  Returns `{:ok, run}` (with `:session` preloaded) or `{:error, reason}`.
  """
  def close_run(%Run{} = run, attrs) do
    outcome_status = attrs[:status] || attrs["status"]

    Repo.transaction(fn ->
      with {:ok, status} <- validate_outcome_status(outcome_status),
           {:ok, in_flight_run} <- claim_in_flight(run),
           {:ok, updated} <- persist_close(in_flight_run, attrs, status) do
        maybe_close_session(updated)
        {:ok, updated}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {:ok, updated}} ->
        broadcast_run_change(updated, :closed)
        {:ok, updated}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Update the phase-level `progress` of an `in_flight` run (P4).

  Overwrite semantics (decisión ?02): the map REPLACES the stored
  `progress`. Never changes `status` — a pending run cannot fake
  progress, a closed run cannot be resurrected. Expected shape (free,
  display-only): `%{\"phase\" => \"implementing\", \"gates\" =>
  %{\"compile\" => \"ok\"}}`.

  Returns `{:ok, run}` or `{:error, :not_in_flight | :run_not_found}`.
  """
  def update_progress(run_id, progress, opts \\ []) when is_binary(run_id) do
    actor_id = Keyword.get(opts, :actor_id)

    {count, _} =
      from(r in Run, where: r.id == ^run_id and r.status == "in_flight")
      |> Repo.update_all(
        set: [progress: progress, updated_at: DateTime.utc_now()] ++ actor_set(actor_id)
      )

    if count == 1 do
      run = Repo.get!(Run, run_id)
      broadcast_run_change(run, :progress)
      {:ok, run}
    else
      actual = Repo.get(Run, run_id)
      if is_nil(actual), do: {:error, :run_not_found}, else: {:error, :not_in_flight}
    end
  end

  @doc """
  Retry a failed run: creates a NEW run of the same `(session_id, step_id)`
  with `attempt: latest + 1` (computed from the DB, not from the struct),
  `pending`. Only allowed when the run is `failed` AND is the LATEST
  attempt of its step (a retry superseded by a newer attempt returns
  `{:error, {:superseded, status}}`). Retrying after the session
  auto-closed as `failed` reopens it to `in_flight`; `aborted` and
  `passed` sessions are terminal — retry is refused. Reopen + insert in
  one transaction: a failed insert restores the closed session.
  """
  def retry_run(%Run{} = run) do
    Repo.transaction(fn ->
      with :ok <- assert_run_status(run, "failed"),
           {:ok, latest} <- latest_attempt(run.session_id, run.step_id),
           :ok <- assert_retryable(latest),
           :ok <- reopen_session_if_closed(run.session_id),
           {:ok, new_run} <- build_retry(latest, latest.attempt + 1) do
        {:ok, new_run}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {:ok, new_run}} ->
        broadcast_run_change(new_run, :created)
        {:ok, new_run}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Abort an open session: its pending/in_flight runs are closed as
  `skipped` (outcome \"session aborted\"), the session moves to
  `aborted` with `finished_at`, and the change is broadcast.

  The manual escape hatch: a session that is no longer wanted can always
  be closed. Returns `{:ok, session}` or `{:error, reason}`
  (`:session_closed` when the session is not open).
  """
  def abort_session(%WorkflowSession{} = session) do
    Repo.transaction(fn ->
      with :ok <- assert_session_open(%Run{session_id: session.id}) do
        from(r in Run,
          where: r.session_id == ^session.id and r.status in ~w(pending in_flight)
        )
        |> Repo.update_all(
          set: [status: "skipped", outcome: "session aborted", updated_at: DateTime.utc_now()]
        )

        closed =
          session
          |> WorkflowSession.changeset(%{status: "aborted", finished_at: DateTime.utc_now()})
          |> Repo.update!()

        closed
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, closed} ->
        broadcast_session_change(closed, :aborted)
        {:ok, closed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Progress of a session as a map: `%{total, pending, in_flight, passed,
  failed, skipped}` — counts over all runs of the session (including
  retries).
  """
  def session_progress(%WorkflowSession{} = session) do
    counts =
      Repo.one(
        from r in Run,
          where: r.session_id == ^session.id,
          select: %{
            total: count(r.id),
            pending:
              coalesce(
                sum(fragment("CASE WHEN ? = 'pending' THEN 1 ELSE 0 END", r.status)),
                0
              ),
            in_flight:
              coalesce(
                sum(fragment("CASE WHEN ? = 'in_flight' THEN 1 ELSE 0 END", r.status)),
                0
              ),
            passed:
              coalesce(
                sum(fragment("CASE WHEN ? = 'passed' THEN 1 ELSE 0 END", r.status)),
                0
              ),
            failed:
              coalesce(
                sum(fragment("CASE WHEN ? = 'failed' THEN 1 ELSE 0 END", r.status)),
                0
              ),
            skipped:
              coalesce(
                sum(fragment("CASE WHEN ? = 'skipped' THEN 1 ELSE 0 END", r.status)),
                0
              )
          }
      )

    counts || %{total: 0, pending: 0, in_flight: 0, passed: 0, failed: 0, skipped: 0}
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Internals
  # ───────────────────────── persisted ───────────────────────────────────────
  # ──────────────────────────────────────────────────────────────────────────

  # An archived workflow must not open new passes; a draft may (agents
  # iterate on drafts) — status only gates archived.
  defp ensure_workflow_runnable(%Dran.Workflow{status: "archived"}),
    do: {:error, :workflow_archived}

  defp ensure_workflow_runnable(%Dran.Workflow{}), do: :ok

  # A workflow with no steps would open a zombie session: no runs means
  # no close_run can ever fire the auto-close.
  defp ensure_workflow_has_steps(%Dran.Workflow{} = workflow) do
    if Dran.Workflows.list_steps(workflow) == [] do
      {:error, :workflow_has_no_steps}
    else
      :ok
    end
  end

  # Frozen definition the session runs against: id/title/contract of every
  # step + the step→step depends_on edges among them (edges = {source,
  # target} tuples as [from, to] pairs).
  defp workflow_snapshot(steps) do
    step_ids = Enum.map(steps, & &1.id)

    edges = Dran.Contracts.dependency_edges(step_ids, :step)

    %{
      "steps" =>
        Enum.map(steps, fn step ->
          %{
            "id" => step.id,
            "title" => step.title,
            "contract" => step.meta["contract"]
          }
        end),
      "edges" => Enum.map(edges, fn {from_id, to_id} -> [from_id, to_id] end)
    }
  end

  defp claim_pending(%Run{} = run, opts) do
    actor_id = Keyword.get(opts, :actor_id)

    {count, _} =
      from(r in Run, where: r.id == ^run.id and r.status == "pending")
      |> Repo.update_all(
        set: [status: "in_flight", updated_at: DateTime.utc_now()] ++ actor_set(actor_id)
      )

    if count == 1 do
      {:ok, Repo.get!(Run, run.id)}
    else
      actual = Repo.get!(Run, run.id).status
      {:error, {:wrong_status, actual, "pending"}}
    end
  end

  # Claims the run for closing with a conditional UPDATE (WHERE status =
  # 'in_flight'): two executors holding the same struct cannot both close —
  # exactly one wins. Returns the fresh run on success.
  defp claim_in_flight(%Run{} = run) do
    {count, _} =
      from(r in Run, where: r.id == ^run.id and r.status == "in_flight")
      |> Repo.update_all(set: [updated_at: DateTime.utc_now()])

    if count == 1, do: {:ok, Repo.get!(Run, run.id)}, else: {:error, :not_in_flight}
  end

  defp validate_outcome_status(status) when status in ~w(passed failed skipped),
    do: {:ok, status}

  defp validate_outcome_status(_status), do: {:error, :invalid_status}

  defp actor_set(nil), do: []
  defp actor_set(actor_id), do: [actor_id: actor_id]

  defp assert_run_status(%Run{status: expected}, expected), do: :ok

  defp assert_run_status(%Run{status: actual}, expected),
    do: {:error, {:wrong_status, actual, expected}}

  defp assert_session_open(%Run{session_id: session_id}) do
    case Repo.get(WorkflowSession, session_id) do
      %WorkflowSession{status: "in_flight"} -> :ok
      _ -> {:error, :session_closed}
    end
  end

  defp persist_close(%Run{} = run, attrs, status) do
    run = Repo.preload(run, :session)

    changeset =
      Run.changeset(run, %{
        status: status,
        outcome: fetch_attr(attrs, :outcome),
        gate_results: fetch_attr(attrs, :gate_results),
        checkpoints: fetch_attr(attrs, :checkpoints)
      })

    case Repo.update(changeset) do
      {:ok, run} -> {:ok, run}
      {:error, changeset} -> {:error, changeset}
    end
  end

  # close_run/2 attrs accept keyword lists AND string-key maps.
  defp fetch_attr(attrs, key) when is_list(attrs) do
    Keyword.get(attrs, key)
  end

  defp fetch_attr(attrs, key) when is_map(attrs) do
    Map.get(attrs, to_string(key)) || Map.get(attrs, key)
  end

  # The authoritative latest attempt of (session, step) straight from the
  # DB — the struct the caller holds may be stale.
  defp latest_attempt(session_id, step_id) do
    case Repo.one(
           from r in Run,
             where: r.session_id == ^session_id and r.step_id == ^step_id,
             order_by: [desc: r.attempt],
             limit: 1
         ) do
      nil -> {:error, :no_runs}
      run -> {:ok, run}
    end
  end

  defp assert_retryable(%Run{status: "failed"}), do: :ok

  defp assert_retryable(%Run{status: actual}),
    do: {:error, {:superseded, actual}}

  # A manual retry of a session auto-closed as `failed` extends the session:
  # it reopens to `in_flight` so the new pending attempt can start. `aborted`
  # is a deliberate human stop and `passed` has no failed latest attempt —
  # both stay terminal.
  defp reopen_session_if_closed(session_id) do
    case Repo.get(WorkflowSession, session_id) do
      %WorkflowSession{status: "in_flight"} ->
        :ok

      %WorkflowSession{status: "failed"} = session ->
        case session
             |> WorkflowSession.changeset(%{status: "in_flight", finished_at: nil})
             |> Repo.update() do
          {:ok, _} -> :ok
          {:error, changeset} -> {:error, changeset}
        end

      %WorkflowSession{status: other} ->
        {:error, {:session_not_retryable, other}}

      nil ->
        {:error, :session_not_found}
    end
  end

  defp maybe_close_session(%Run{} = run) do
    session = run.session || Repo.get(WorkflowSession, run.session_id)

    # Only an open session can close — retry after auto-close keeps the
    # session in its terminal state.
    case session do
      %WorkflowSession{status: "in_flight"} ->
        case remaining_open_runs(session.id) do
          0 -> close_session(session)
          _ -> :ok
        end

      _ ->
        :ok
    end
  end

  defp remaining_open_runs(session_id) do
    Repo.aggregate(
      from(r in Run,
        where: r.session_id == ^session_id and r.status in ~w(pending in_flight)
      ),
      :count
    )
  end

  defp close_session(%WorkflowSession{} = session) do
    status = session_outcome(session.id)

    # Repo.update! — a failed close inside the close_run transaction must
    # ROLLBACK, not silently leave a zombie open session.
    closed =
      session
      |> WorkflowSession.changeset(%{status: status, finished_at: DateTime.utc_now()})
      |> Repo.update!()

    broadcast_session_change(closed, :closed)
  end

  # `passed` when everything ended passed/skipped. With retries, the
  # LATEST attempt per STEP decides — a failed attempt superseded by a
  # passed retry does not doom the session.
  defp session_outcome(session_id) do
    latest =
      Repo.all(
        from r in Run,
          where: r.session_id == ^session_id,
          select: {r.step_id, r.attempt, r.status}
      )
      |> Enum.reduce(%{}, fn {step_id, attempt, status}, acc ->
        case Map.get(acc, step_id) do
          {best_attempt, _} when best_attempt >= attempt -> acc
          _ -> Map.put(acc, step_id, {attempt, status})
        end
      end)

    all_passed? =
      latest != %{} and
        Enum.all?(latest, fn {_step_id, {_attempt, status}} ->
          status in ~w(passed skipped)
        end)

    if all_passed?, do: "passed", else: "failed"
  end

  defp build_retry(%Run{} = run, new_attempt) do
    %Run{}
    |> Run.changeset(%{
      session_id: run.session_id,
      step_id: run.step_id,
      workspace_id: run.workspace_id,
      contract_version: run.contract_version,
      status: "pending",
      attempt: new_attempt,
      actor_id: run.actor_id
    })
    |> Repo.insert()
    |> case do
      {:ok, new_run} -> {:ok, Repo.preload(new_run, :session)}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp broadcast_run_change(%Run{workspace_id: nil}, _action), do: :ok

  defp broadcast_run_change(%Run{} = run, action) do
    Phoenix.PubSub.broadcast(
      Dran.PubSub,
      "workspace:#{run.workspace_id}",
      {:run_changed, action, run}
    )
  rescue
    ArgumentError -> :ok
  end

  defp broadcast_session_change(%WorkflowSession{workspace_id: nil}, _action), do: :ok

  defp broadcast_session_change(%WorkflowSession{} = session, action) do
    Phoenix.PubSub.broadcast(
      Dran.PubSub,
      "workspace:#{session.workspace_id}",
      {:session_changed, action, session}
    )
  rescue
    ArgumentError -> :ok
  end
end
