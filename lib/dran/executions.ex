defmodule Dran.Executions do
  @moduledoc """
  The Executions context — session + run tracking for PLANS (wave B).

  ## The principle

  **The run is the record, not the requirement.** A task is NOT obligated to
  execute inside a workflow: simple human tasks live on the board (kanban +
  done, no runs). The execution layer is opt-in per plan — it exists only
  when someone opens a session (`open_session/2`). Without a session,
  everything works exactly as before.

  ## Model (plans/steps/tasks, wave B)

  - `goal_sessions` — an instance of a PLAN (one pass over the stable,
    never-cloned plan), frozen into `plan_snapshot` at open time
    (`%{"steps" => [...], "edges" => [[from, to]]}`). A plan can have N
    sessions, even simultaneous, each with its own context. `goal_id` stays
    as a denormalized column (the goal the plan `serves`, resolved at open
    time and used directly by the close-path recompute).
  - `task_runs` — one execution attempt of a STEP within a session. Runs are
    created upfront (all `pending`) when the session opens, keyed by
    `step_id`. Retries are new runs with `attempt: n + 1`. The TASK is
    spawned by `start_run/1` (instance_of step + part_of goal) — a pending
    or retried run has no task until it starts, and the spawn is idempotent.
  - The dual closure converges: an agent closes through `close_run/2`
    (which terminalizes the spawned task), a human closes through the board
    (`reconcile_task_closure/1`, which terminalizes the run).

  ## Rules baked into this context

  - `run_ready?/1` — prerequisites (`step→step depends_on`, via
    `Dran.Contracts.prerequisite_ids/1`) must have a `passed` run IN THE
    SESSION of the run. Two simultaneous sessions over the same plan never
    block each other (session-scoped sequencing). Every step of the plan has
    a run in its session, so there is no board-status fallback for steps.
  - `close_run/2` — writeback on the SPAWNED task: `passed` → `done` via the
    existing `Dran.Tasks.update_task/2` (idempotent: an already-done task
    does not re-trigger recompute nor clone), `failed` → the task is left
    as-is (a retry cancels it), `skipped` → `cancelled`. Closing the last
    open run closes the session (`passed`/`failed`), stamps `finished_at`,
    archives every spawned task of the session and recomputes the goal.
  - `abort_session/1` — the manual escape hatch: open runs → `skipped`,
    spawned tasks of in-flight runs → `cancelled`, ALL spawned tasks of the
    session → `archived`, session → `aborted` + recompute.
  - `gate_results` and `checkpoints` are DATA (the executor's report), never
    enforced server-side.
  """

  import Ecto.Query, warn: false

  alias Dran.Repo
  alias Dran.GoalSession
  alias Dran.TaskRun

  @doc """
  Open a session for a PLAN: creates the `in_flight` session plus `pending`
  runs (attempt 1) for EVERY step of the plan, and freezes the `plan_snapshot`.

  The plan's goal is resolved via its `serves` relation (wave A) and kept as
  the denormalized `goal_id`. `plan_snapshot` is `%{"steps" => [%{"id",
  "title", "contract"}], "edges" => [[from_id, to_id]]}` — the step→step
  `depends_on` edges at open time (same shape the migration backfill used).
  Each run snapshots `step.meta["contract"]` into `contract_version` (nil
  when the step has no contract).

  Returns `{:ok, session}` (with `:runs` preloaded) or
  `{:error, :plan_serves_no_goal | reason}` — the session and all its runs
  are created in a single transaction.
  """
  def open_session(%Dran.Plan{} = plan, opts \\ []) do
    workspace_id = plan.workspace_id
    label = Keyword.get(opts, :label)
    context = Keyword.get(opts, :context, %{})
    actor_id = Keyword.get(opts, :actor_id)
    started_at = DateTime.utc_now()

    with {:ok, goal} <- served_goal(plan),
         :ok <- ensure_plan_has_steps(plan) do
      Repo.transaction(fn ->
        steps = Dran.Plans.list_steps(plan)
        snapshot = plan_snapshot(steps)

        session =
          %GoalSession{}
          |> GoalSession.changeset(%{
            plan_id: plan.id,
            goal_id: goal.id,
            workspace_id: workspace_id,
            plan_snapshot: snapshot,
            label: label,
            context: context,
            status: "in_flight",
            actor_id: actor_id,
            started_at: started_at
          })
          |> Repo.insert!()

        Enum.each(steps, fn step ->
          %TaskRun{}
          |> TaskRun.changeset(%{
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
  def get_session!(id), do: Repo.get!(GoalSession, id)

  @doc "List all sessions of a goal, most recent first (goal_id is denormalized)."
  def list_sessions(%Dran.Goal{} = goal) do
    Repo.all(
      from s in GoalSession,
        where: s.goal_id == ^goal.id,
        order_by: [desc: s.inserted_at]
    )
  end

  @doc "List the runs of a session, most recent first."
  def list_runs(%GoalSession{} = session) do
    Repo.all(
      from r in TaskRun,
        where: r.session_id == ^session.id,
        order_by: [desc: r.inserted_at]
    )
  end

  @doc """
  Is the run ready to execute?

  Prerequisites are resolved from the session's FROZEN `plan_snapshot`
  edges — NOT from live step→step relations. The snapshot is the topology
  that pass was opened with: editing the plan mid-session (adding/removing
  edges) never re-sequences an open session (design decision, review MAJOR).

  A run is ready when every direct prerequisite of its step (per the
  snapshot) has a `passed` run IN THE SESSION of this run. No prerequisites
  → ready. Deliberately session-scoped: two simultaneous sessions over the
  same plan never block each other.
  """
  def run_ready?(%TaskRun{} = run) do
    prerequisite_ids = snapshot_prerequisite_ids(run)

    prerequisite_ids == [] or prereqs_satisfied?(run.session_id, prerequisite_ids)
  end

  # Direct prerequisites of the run's step per the FROZEN snapshot edges.
  # Snapshot edges are [from=dependiente, to=prereq] pairs — a prereq of X
  # is any edge whose first element is X.
  defp snapshot_prerequisite_ids(%TaskRun{} = run) do
    session =
      case run.session do
        %GoalSession{} = loaded -> loaded
        _not_loaded -> Repo.get!(GoalSession, run.session_id)
      end

    session.plan_snapshot
    |> Map.get("edges", [])
    |> Enum.filter(fn [from, _to] -> from == run.step_id end)
    |> Enum.map(fn [_from, to] -> to end)
  end

  # ALL prerequisites must be satisfied, each by a passed run IN THIS
  # SESSION (P3). A passed run is always the latest attempt of its step in
  # the session (retries only spawn from failed runs), so any passed run of
  # a prerequisite counts.
  defp prereqs_satisfied?(session_id, prerequisite_step_ids) do
    statuses =
      Repo.all(
        from r in TaskRun,
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
        # Cross-plan edge: no run in this session, and steps have no board
        # status — never satisfied (wave B, no F1 board fallback).
        true -> false
      end
    end)
  end

  @doc """
  Move a run from `pending` to `in_flight` and spawn its task (the
  executor grabs it).

  The claim is a conditional UPDATE (`WHERE status = 'pending'`), so two
  concurrent dispatchers can never both claim the same run — exactly one
  wins, the loser gets `{:error, {:wrong_status, actual, "pending"}}`.
  Refuses runs of a closed session.

  Spawning (idempotent — a run that already has `task_id` is never
  re-spawned): a `todo` task is created from the step (title/body, contract
  = the frozen `contract_version`) and linked `instance_of` the step and
  `part_of` the plan's goal; `run.task_id` is set. Claim + spawn happen in
  one transaction — a failed spawn restores the run to `pending`.
  """
  def start_run(%TaskRun{} = run) do
    Repo.transaction(fn ->
      with :ok <- assert_session_open(run),
           {:ok, claimed} <- claim_pending(run),
           {:ok, spawned} <- ensure_spawned(claimed) do
        {:ok, spawned}
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

  `attrs`: `outcome` (summary), `gate_results` (map, per-gate report),
  `checkpoints` (map of ✓NN ledger entries), `status` (one of
  `passed | failed | skipped`).

  ## Rules (wave B, decisions ?03/?05/?07)

  - `passed` → the SPAWNED task moves to `done` via
    `Dran.Tasks.update_task/2` — idempotent: an already-done task does not
    change status, so it does not re-trigger goal recompute nor recurrence
    clones.
  - `failed` → the spawned task is NEVER touched (a retry cancels it).
  - `skipped` → the spawned task moves to `cancelled`.
  - Closing the last open run (`pending | in_flight`) of the session closes
    the session: `passed` when all runs (latest attempt per step) are
    `passed`/`skipped`, `failed` otherwise, `finished_at` stamped now, every
    spawned task of the session archived, and
    `Dran.Goals.recompute_progress/1` runs on the closed pass.

  Returns `{:ok, run}` (with `:session` preloaded) or `{:error, reason}`.
  """
  def close_run(%TaskRun{} = run, attrs) do
    outcome_status = attrs[:status] || attrs["status"]

    Repo.transaction(fn ->
      with {:ok, status} <- validate_outcome_status(outcome_status),
           {:ok, in_flight_run} <- claim_in_flight(run),
           {:ok, updated} <- persist_close(in_flight_run, attrs, status) do
        # El writeback corre dentro de la txn: si update_task falla tira y
        # revierte TODO (nunca un run cerrado con la task sin terminalizar).
        apply_task_effects(updated, status)

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

  # Claims the run for closing with a conditional UPDATE (WHERE status =
  # 'in_flight'): two executors holding the same struct cannot both close —
  # exactly one wins. Returns the fresh run on success.
  defp claim_in_flight(%TaskRun{} = run) do
    {count, _} =
      from(r in TaskRun, where: r.id == ^run.id and r.status == "in_flight")
      |> Repo.update_all(set: [updated_at: DateTime.utc_now()])

    if count == 1, do: {:ok, Repo.get!(TaskRun, run.id)}, else: {:error, :not_in_flight}
  end

  defp validate_outcome_status(status) when status in ~w(passed failed skipped),
    do: {:ok, status}

  defp validate_outcome_status(_status), do: {:error, :invalid_status}

  @doc """
  Retry a failed run: creates a NEW run of the same `(session_id, step_id)`
  with `attempt: latest + 1` (computed from the DB, not from the struct),
  `pending`, and cancels the task of the failed attempt being replaced.
  Only allowed when the run is `failed` AND is the LATEST attempt of its
  step (a retry superseded by a newer attempt returns
  `{:error, {:superseded, status}}`). Retrying after the session auto-closed
  as `failed` reopens it to `in_flight` (decision 6 is manual); `aborted`
  and `passed` sessions are terminal — retry is refused. Reopen + insert
  run + cancel in one transaction: a failed insert restores the closed
  session.
  """
  def retry_run(%TaskRun{} = run) do
    Repo.transaction(fn ->
      with :ok <- assert_run_status(run, "failed"),
           {:ok, latest} <- latest_attempt(run.session_id, run.step_id),
           :ok <- assert_retryable(latest),
           :ok <- reopen_session_if_closed(run.session_id),
           {:ok, new_run} <- build_retry(latest, latest.attempt + 1) do
        cancel_previous_attempt(latest)
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

  # The authoritative latest attempt of (session, step) straight from the
  # DB — the struct the caller holds may be stale.
  defp latest_attempt(session_id, step_id) do
    case Repo.one(
           from r in TaskRun,
             where: r.session_id == ^session_id and r.step_id == ^step_id,
             order_by: [desc: r.attempt],
             limit: 1
         ) do
      nil -> {:error, :no_runs}
      run -> {:ok, run}
    end
  end

  defp assert_retryable(%TaskRun{status: "failed"}), do: :ok

  defp assert_retryable(%TaskRun{status: actual}),
    do: {:error, {:superseded, actual}}

  # A manual retry of a session auto-closed as `failed` extends the session:
  # it reopens to `in_flight` so the new pending attempt can start (decision
  # 6 is manual; decision 7 only auto-closes on run close events). `aborted`
  # is a deliberate human stop and `passed` has no failed latest attempt —
  # both stay terminal.
  defp reopen_session_if_closed(session_id) do
    case Repo.get(GoalSession, session_id) do
      %GoalSession{status: "in_flight"} ->
        :ok

      %GoalSession{status: "failed"} = session ->
        case session
             |> GoalSession.changeset(%{status: "in_flight", finished_at: nil})
             |> Repo.update() do
          {:ok, _} -> :ok
          {:error, changeset} -> {:error, changeset}
        end

      %GoalSession{status: other} ->
        {:error, {:session_not_retryable, other}}

      nil ->
        {:error, :session_not_found}
    end
  end

  @doc """
  Abort an open session: its pending/in_flight runs are closed as `skipped`
  (outcome "session aborted"), the spawned task of every in-flight run is
  `cancelled`, ALL spawned tasks of the session are `archived`, the session
  moves to `aborted` with `finished_at`, the goal progress is recomputed and
  the change broadcast.

  The manual escape hatch: a session whose steps were cancelled or archived
  mid-flight (or that is simply no longer wanted) can always be closed.
  Returns `{:ok, session}` or `{:error, reason}` (`:session_closed` when
  the session is not open).
  """
  def abort_session(%GoalSession{} = session) do
    Repo.transaction(fn ->
      with :ok <- assert_session_open(%TaskRun{session_id: session.id}) do
        in_flight_task_ids =
          Repo.all(
            from r in TaskRun,
              where: r.session_id == ^session.id and r.status == "in_flight",
              select: r.task_id
          )
          |> Enum.reject(&is_nil/1)

        from(r in TaskRun,
          where: r.session_id == ^session.id and r.status in ~w(pending in_flight)
        )
        |> Repo.update_all(
          set: [status: "skipped", outcome: "session aborted", updated_at: DateTime.utc_now()]
        )

        cancel_tasks(in_flight_task_ids)
        archive_session_tasks(session.id)

        closed =
          session
          |> GoalSession.changeset(%{status: "aborted", finished_at: DateTime.utc_now()})
          |> Repo.update!()

        Dran.Goals.recompute_progress(Repo.get!(Dran.Goal, closed.goal_id))
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
  Human-side twin of `close_run/2`: closes the `in_flight` run whose task
  reached a terminal state through the BOARD.

  A task `done` by hand → run `passed` (outcome "manual", empty gates); a
  task `cancelled` by hand → run `skipped` (outcome "manual", empty gates).
  Looks up the run by `task_id`; no-op (`{:ok, :noop}`) when there is no
  open run for the task (never spawned, or already closed by the agent).
  This is what makes the dual closure converge: `maybe_close_session/1`
  applies here exactly as in `close_run/2`.
  """
  def reconcile_task_closure(%Dran.Task{} = task) do
    case Repo.one(
           from r in TaskRun,
             where: r.task_id == ^task.id and r.status == "in_flight",
             order_by: [desc: r.attempt],
             limit: 1
         ) do
      %TaskRun{status: "in_flight"} = run ->
        case task.status do
          "done" -> close_run(run, status: "passed", outcome: "manual", gate_results: %{})
          "cancelled" -> close_run(run, status: "skipped", outcome: "manual", gate_results: %{})
          _other -> {:ok, :noop}
        end

      nil ->
        {:ok, :noop}
    end
  end

  @doc """
  Progress of a session as a map: `%{total, pending, in_flight, passed, failed, skipped}` — counts over all runs of the session (including retries).
  """
  def session_progress(%GoalSession{} = session) do
    counts =
      Repo.one(
        from r in TaskRun,
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
  # ──────────────────────────────────────────────────────────────────────────

  # The goal a plan serves (wave A `serves` relation, plan → goal).
  # Ambiguity is an explicit error, not a crash: nothing structurally
  # prevents two serves rows from one plan (review finding).
  defp served_goal(%Dran.Plan{} = plan) do
    case Repo.all(
           from r in Dran.Relation,
             where:
               r.source_id == ^plan.id and r.source_type == "plan" and
                 r.target_type == "goal" and r.relation_type == "serves",
             select: r.target_id
         ) do
      [] -> {:error, :plan_serves_no_goal}
      [goal_id] -> {:ok, Repo.get!(Dran.Goal, goal_id)}
      _many -> {:error, :ambiguous_goal}
    end
  end

  # A plan with no steps would open a zombie session: no runs means no
  # close_run can ever fire the auto-close (review finding).
  defp ensure_plan_has_steps(%Dran.Plan{} = plan) do
    if Dran.Plans.list_steps(plan) == [] do
      {:error, :plan_has_no_steps}
    else
      :ok
    end
  end

  # Frozen definition the session runs against: id/title/contract of every
  # step + the step→step depends_on edges among them (same shape as the
  # migration backfill; edges = {source, target} tuples as [from, to] pairs).
  defp plan_snapshot(steps) do
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

  defp claim_pending(%TaskRun{} = run) do
    {count, _} =
      from(r in TaskRun, where: r.id == ^run.id and r.status == "pending")
      |> Repo.update_all(set: [status: "in_flight", updated_at: DateTime.utc_now()])

    if count == 1 do
      {:ok, Repo.get!(TaskRun, run.id)}
    else
      actual = Repo.get!(TaskRun, run.id).status
      {:error, {:wrong_status, actual, "pending"}}
    end
  end

  # Idempotent spawn: a run that already carries a task is never
  # re-spawned (the conditional claim guarantees only one concurrent
  # starter reaches the spawn branch).
  defp ensure_spawned(%TaskRun{task_id: task_id} = run) when not is_nil(task_id),
    do: {:ok, run}

  defp ensure_spawned(%TaskRun{} = run) do
    with {:ok, session} <- fetch_open_session(run.session_id),
         {:ok, step} <- fetch_step(run.step_id),
         {:ok, task} <- create_spawned_task(run, step),
         {:ok, _} <- link_part_of(task, session),
         {:ok, _} <- link_instance_of(task, step),
         {:ok, run} <- attach_task(run, task) do
      {:ok, run}
    end
  end

  # Re-read of the session status AFTER the claim: closes the TOCTOU window
  # where the last other run's close commits between our claim and the spawn
  # (review finding — the session must still be open when we materialize).
  defp fetch_open_session(session_id) do
    case Repo.get(GoalSession, session_id) do
      %GoalSession{status: "in_flight"} = session -> {:ok, session}
      %GoalSession{} -> {:error, :session_closed}
      nil -> {:error, :session_not_found}
    end
  end

  defp fetch_step(step_id) do
    case Repo.get(Dran.Step, step_id) do
      %Dran.Step{} = step -> {:ok, step}
      nil -> {:error, :step_not_found}
    end
  end

  # The spawned task is created ONLY via Tasks.create_task/1 (never Repo
  # direct to tasks): slug/owner defaults + board broadcast included. The
  # contract comes from the frozen run snapshot, not the live step.
  defp create_spawned_task(%TaskRun{} = run, %Dran.Step{} = step) do
    Dran.Tasks.create_task(%{
      "workspace_id" => run.workspace_id,
      "title" => step.title,
      "body" => step.body || "",
      "status" => "todo",
      "meta" => %{"contract" => run.contract_version}
    })
  end

  # task → goal, so the goal's recompute (Snippet 2) covers the spawned
  # automatically. Uses the real Tasks path (recompute + broadcast).
  defp link_part_of(%Dran.Task{} = task, %GoalSession{} = session) do
    Dran.Tasks.link_to_goal(task, Repo.get!(Dran.Goal, session.goal_id))
  end

  # task → step: the spawned task is an instance of its step.
  defp link_instance_of(%Dran.Task{} = task, %Dran.Step{} = step) do
    %Dran.Relation{}
    |> Dran.Relation.changeset(%{
      source_id: task.id,
      source_type: "task",
      target_id: step.id,
      target_type: "step",
      relation_type: "instance_of"
    })
    |> Repo.insert(on_conflict: :nothing)
  end

  defp attach_task(%TaskRun{} = run, %Dran.Task{} = task) do
    run
    |> TaskRun.changeset(%{task_id: task.id})
    |> Repo.update()
  end

  defp assert_run_status(%TaskRun{status: expected}, expected), do: :ok

  defp assert_run_status(%TaskRun{status: actual}, expected),
    do: {:error, {:wrong_status, actual, expected}}

  defp assert_session_open(%TaskRun{session_id: session_id}) do
    case Repo.get(GoalSession, session_id) do
      %GoalSession{status: "in_flight"} -> :ok
      _ -> {:error, :session_closed}
    end
  end

  defp assert_session_open(%GoalSession{} = session),
    do: assert_session_open(%TaskRun{session_id: session.id})

  defp persist_close(%TaskRun{} = run, attrs, status) do
    run =
      run
      |> Repo.preload(:session)

    changeset =
      TaskRun.changeset(run, %{
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

  # Wave B effects on the SPAWNED task, inside the close transaction:
  # passed → done, skipped → cancelled, failed → untouched (a retry cancels
  # the failed attempt's task). Idempotent per terminal state — and a task
  # already terminal (e.g. cancelled by a human mid-race) is NEVER
  # resurrected: the agent's passed does not override the board (review
  # finding).
  defp apply_task_effects(%TaskRun{task_id: nil}, _status), do: :ok

  defp apply_task_effects(%TaskRun{task_id: task_id}, status) do
    case Repo.get(Dran.Task, task_id) do
      %Dran.Task{status: current} = task ->
        cond do
          current in ~w(done cancelled) ->
            :ok

          status == "passed" ->
            Dran.Tasks.update_task(task, %{"status" => "done"})

          status == "skipped" ->
            Dran.Tasks.update_task(task, %{"status" => "cancelled"})

          true ->
            :ok
        end

      nil ->
        :ok
    end

    :ok
  end

  defp cancel_previous_attempt(%TaskRun{task_id: nil}), do: :ok

  defp cancel_previous_attempt(%TaskRun{task_id: task_id}) do
    case Repo.get(Dran.Task, task_id) do
      %Dran.Task{status: "cancelled"} -> :ok
      %Dran.Task{} = task -> Dran.Tasks.update_task(task, %{"status" => "cancelled"})
      nil -> :ok
    end

    :ok
  end

  defp cancel_tasks(task_ids) do
    Enum.each(task_ids, fn task_id ->
      case Repo.get(Dran.Task, task_id) do
        %Dran.Task{} = task -> Dran.Tasks.update_task(task, %{"status" => "cancelled"})
        nil -> :ok
      end
    end)
  end

  defp maybe_close_session(%TaskRun{} = run) do
    session = run.session || Repo.get(GoalSession, run.session_id)

    # Only an open session can close — retry after auto-close keeps the
    # session in its terminal state (decision 7 applies to the first pass).
    case session do
      %GoalSession{status: "in_flight"} ->
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
      from(r in TaskRun,
        where: r.session_id == ^session_id and r.status in ~w(pending in_flight)
      ),
      :count
    )
  end

  defp close_session(%GoalSession{} = session) do
    status = session_outcome(session.id)
    archive_session_tasks(session.id)

    # Repo.update! — a failed close inside the close_run transaction must
    # ROLLBACK, not silently leave a zombie open session (review finding).
    closed =
      session
      |> GoalSession.changeset(%{status: status, finished_at: DateTime.utc_now()})
      |> Repo.update!()

    Dran.Goals.recompute_progress(Repo.get(Dran.Goal, closed.goal_id))
    broadcast_session_change(closed, :closed)
  end

  # Decision ?07: every task spawned by the session (any run carrying a
  # task_id) is archived — spawned tasks are execution artifacts, not board
  # items; the goal's recompute (Snippet 2) ignores archived tasks.
  defp archive_session_tasks(session_id) do
    task_ids =
      Repo.all(
        from r in TaskRun,
          where: r.session_id == ^session_id and not is_nil(r.task_id),
          select: r.task_id,
          distinct: true
      )
      |> Enum.reject(&is_nil/1)

    Enum.each(task_ids, fn task_id ->
      case Repo.get(Dran.Task, task_id) do
        %Dran.Task{} = task -> Dran.Tasks.update_task(task, %{"archived" => true})
        nil -> :ok
      end
    end)
  end

  # Decision 7: `passed` when everything ended passed/skipped, `failed`
  # otherwise. With retries, the LATEST attempt per STEP decides — a failed
  # attempt superseded by a passed retry does not doom the session.
  defp session_outcome(session_id) do
    latest =
      Repo.all(
        from r in TaskRun,
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

  defp build_retry(%TaskRun{} = run, new_attempt) do
    %TaskRun{}
    |> TaskRun.changeset(%{
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

  defp broadcast_run_change(%TaskRun{workspace_id: nil}, _action), do: :ok

  defp broadcast_run_change(%TaskRun{} = run, action) do
    Phoenix.PubSub.broadcast(
      Dran.PubSub,
      "workspace:#{run.workspace_id}",
      {:run_changed, action, run}
    )
  rescue
    ArgumentError -> :ok
  end

  defp broadcast_session_change(%GoalSession{workspace_id: nil}, _action), do: :ok

  defp broadcast_session_change(%GoalSession{} = session, action) do
    Phoenix.PubSub.broadcast(
      Dran.PubSub,
      "workspace:#{session.workspace_id}",
      {:session_changed, action, session}
    )
  rescue
    ArgumentError -> :ok
  end
end
