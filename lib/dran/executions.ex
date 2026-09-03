defmodule Dran.Executions do
  @moduledoc """
  The Executions context — session + run tracking for goals (F1).

  ## The principle

  **The run is the record, not the requirement.** A task is NOT obligated to
  execute inside a workflow: simple human tasks live on the board (kanban +
  done, no runs). The execution layer is opt-in per goal — it exists only
  when someone opens a session (`open_session/2`). Without a session,
  everything works exactly as before.

  ## Model

  - `goal_sessions` — an instance of a goal (one pass over the stable,
    never-cloned plan). A goal can have N sessions, even simultaneous, each
    with its own context.
  - `task_runs` — one execution attempt of a task step within a session.
    Runs are created upfront (all `pending`) when the session opens
    (decisions 4 & 5: active steps = `part_of` tasks with
    `archived == false`, `status != "cancelled"` and `recurrence == "none"`
    — recurring tasks are excluded, repetition in flows comes from the
    sessions themselves). Retries are new runs with `attempt: n + 1`.

  ## Rules baked into this context

  - `run_ready?/1` — prerequisites (`depends_on`) must have a `passed` run
    IN THE SESSION of the run. Two simultaneous sessions over the same plan
    never block each other (session-scoped sequencing).
  - `close_run/2` — writeback: a `passed` run moves the task to `done` via
    the existing `Dran.Tasks.update_task/2` (idempotent: an already-done task
    does not re-trigger recompute nor clone). `failed`/`skipped` NEVER touch
    `task.status`. Closing the last open run closes the session
    (`passed`/`failed`), stamps `finished_at` and recomputes the goal.
  - `gate_results` and `checkpoints` are DATA (the executor's report), never
    enforced server-side (decision 8).
  """

  import Ecto.Query, warn: false

  alias Dran.Repo
  alias Dran.GoalSession
  alias Dran.TaskRun

  @doc """
  Open a session for a goal: creates the `in_flight` session plus `pending`
  runs (attempt 1) for every active step of the goal.

  Active steps (decisions 4 & 5, base set = same total as
  `Dran.Goals.recompute_progress/1`): tasks linked `part_of` the goal with
  `archived == false` and `status != "cancelled"`, EXCLUDING recurring tasks
  (`recurrence != "none"` — repetition in flows comes from sessions, not
  from clones). Each run snapshots `task.meta["contract"]` into
  `contract_version` (decision 2, nil when the task has no contract).

  Returns `{:ok, session}` (with `:runs` preloaded) or `{:error, reason}` —
  the session and all its runs are created in a single transaction.
  """
  def open_session(%Dran.Goal{} = goal, opts \\ []) do
    workspace_id = goal.workspace_id
    label = Keyword.get(opts, :label)
    context = Keyword.get(opts, :context, %{})
    actor_id = Keyword.get(opts, :actor_id)
    started_at = DateTime.utc_now()

    Repo.transaction(fn ->
      session =
        %GoalSession{}
        |> GoalSession.changeset(%{
          goal_id: goal.id,
          workspace_id: workspace_id,
          label: label,
          context: context,
          status: "in_flight",
          actor_id: actor_id,
          started_at: started_at
        })
        |> Repo.insert!()

      tasks = active_steps(goal)

      Enum.each(tasks, fn task ->
        %TaskRun{}
        |> TaskRun.changeset(%{
          session_id: session.id,
          task_id: task.id,
          workspace_id: workspace_id,
          contract_version: task.meta["contract"],
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

  @doc "Get a session by id, raises if missing."
  def get_session!(id), do: Repo.get!(GoalSession, id)

  @doc "List all sessions of a goal, most recent first."
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

  A run is ready when every direct prerequisite of its task (`depends_on`
  edges) has a `passed` run IN THE SESSION of this run. If the task has no
  prerequisites, it is ready. This is deliberately session-scoped: two
  simultaneous sessions over the same plan never block each other (P3). It
  does NOT reuse `Dran.Contracts.dependency_states/1`, which is global per
  `task.status`.
  """
  def run_ready?(%TaskRun{} = run) do
    task_id = run.task_id || run.task.id

    prerequisite_ids = Dran.Contracts.prerequisite_ids(%Dran.Task{id: task_id})

    prerequisite_ids == [] or prereqs_satisfied?(run.session_id, prerequisite_ids)
  end

  # ALL prerequisites must be satisfied, each by a passed run IN THIS
  # SESSION (P3). A prereq task with NO run in the session (a cross-goal
  # edge, or a step excluded at open time) falls back to its board status:
  # an external `done` prereq does not block — same semantics as the global
  # `Dran.Contracts.dependency_states/1` model. A passed run is always the
  # latest attempt of its task in the session (retries only spawn from
  # failed runs), so any passed run of a prereq counts.
  defp prereqs_satisfied?(session_id, prerequisite_ids) do
    statuses =
      Repo.all(
        from r in TaskRun,
          where: r.session_id == ^session_id and r.task_id in ^prerequisite_ids,
          select: {r.task_id, r.status}
      )

    passed_tasks =
      statuses
      |> Enum.filter(fn {_task_id, status} -> status == "passed" end)
      |> Enum.map(&elem(&1, 0))
      |> MapSet.new()

    tasks_with_runs = statuses |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    Enum.all?(prerequisite_ids, fn task_id ->
      cond do
        MapSet.member?(passed_tasks, task_id) -> true
        MapSet.member?(tasks_with_runs, task_id) -> false
        true -> task_done?(task_id)
      end
    end)
  end

  defp task_done?(task_id) do
    Repo.exists?(from t in Dran.Task, where: t.id == ^task_id and t.status == "done")
  end

  @doc """
  Move a run from `pending` to `in_flight` (the executor grabs it).

  The claim is a conditional UPDATE (`WHERE status = 'pending'`), so two
  concurrent dispatchers can never both claim the same run — exactly one
  wins, the loser gets `{:error, {:wrong_status, actual, "pending"}}`.
  Refuses runs of a closed session.
  """
  def start_run(%TaskRun{} = run) do
    with :ok <- assert_session_open(run) do
      {count, _} =
        from(r in TaskRun, where: r.id == ^run.id and r.status == "pending")
        |> Repo.update_all(set: [status: "in_flight", updated_at: DateTime.utc_now()])

      if count == 1 do
        updated = Repo.get!(TaskRun, run.id)
        broadcast_run_change(updated, :started)
        {:ok, updated}
      else
        actual = Repo.get!(TaskRun, run.id).status
        {:error, {:wrong_status, actual, "pending"}}
      end
    end
  end

  @doc """
  Close a run with a result.

  `attrs`: `outcome` (summary), `gate_results` (map, per-gate report),
  `checkpoints` (map of ✓NN ledger entries), `status` (one of
  `passed | failed | skipped`).

  ## Rules (decisions 3 & 7)

  - `passed` → writeback via `Dran.Tasks.update_task(task, %{status: "done"})`
    — idempotent: an already-done task does not change status, so it does not
    re-trigger goal recompute nor recurrence clones.
  - `failed` / `skipped` → `task.status` is NEVER touched.
  - Closing the last open run (`pending | in_flight`) of the session closes
    the session: `passed` when all runs are `passed`/`skipped`, `failed`
    otherwise (some run failed), `finished_at` stamped now, and
    `Dran.Goals.recompute_progress/1` runs on the closed pass.

  Returns `{:ok, run}` (with `:session` preloaded) or `{:error, reason}`.
  """
  def close_run(%TaskRun{} = run, attrs) do
    outcome_status = attrs[:status] || attrs["status"]

    Repo.transaction(fn ->
      with {:ok, status} <- validate_outcome_status(outcome_status),
           {:ok, in_flight_run} <- claim_in_flight(run),
           {:ok, updated} <- persist_close(in_flight_run, attrs, status) do
        if status == "passed" do
          # El writeback corre dentro de la txn: si update_task falla tira y
          # revierte TODO (nunca un run passed con la task sin done).
          writeback_passed(updated)
        end

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
  Retry a failed run: creates a NEW run of the same `(session_id, task_id)`
  with `attempt: latest + 1` (computed from the DB, not from the struct),
  `pending`. Only allowed when the run is `failed` AND is the LATEST attempt
  of its task (a retry superseded by a newer attempt returns
  `{:error, {:superseded, status}}`). Retrying after the session auto-closed
  as `failed` reopens it to `in_flight` (decision 6 is manual); `aborted`
  and `passed` sessions are terminal — retry is refused. Reopen + insert
  run in one transaction: a failed insert restores the closed session.
  """
  def retry_run(%TaskRun{} = run) do
    Repo.transaction(fn ->
      with :ok <- assert_run_status(run, "failed"),
           {:ok, latest} <- latest_attempt(run.session_id, run.task_id),
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

  # The authoritative latest attempt of (session, task) straight from the
  # DB — the struct the caller holds may be stale.
  defp latest_attempt(session_id, task_id) do
    case Repo.one(
           from r in TaskRun,
             where: r.session_id == ^session_id and r.task_id == ^task_id,
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
  (outcome "session aborted"), the session moves to `aborted` with
  `finished_at`, the goal progress is recomputed and the change broadcast.

  The manual escape hatch: a session whose steps were cancelled or archived
  mid-flight (or that is simply no longer wanted) can always be closed.
  Returns `{:ok, session}` or `{:error, reason}` (`:session_closed` when
  the session is not open).
  """
  def abort_session(%GoalSession{} = session) do
    Repo.transaction(fn ->
      with :ok <- assert_session_open(%TaskRun{session_id: session.id}) do
        from(r in TaskRun,
          where: r.session_id == ^session.id and r.status in ~w(pending in_flight)
        )
        |> Repo.update_all(
          set: [status: "skipped", outcome: "session aborted", updated_at: DateTime.utc_now()]
        )

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

  # Steps of the goal that get a run upfront (decisions 4 & 5), one query:
  # part_of + not archived + not cancelled + NOT recurring.
  defp active_steps(%Dran.Goal{} = goal) do
    Repo.all(
      from t in Dran.Task,
        join: r in Dran.Relation,
        on:
          r.source_id == t.id and r.source_type == "task" and
            r.target_type == "goal" and r.relation_type == "part_of" and
            r.target_id == ^goal.id,
        where:
          t.archived == false and t.status != "cancelled" and
            t.recurrence == "none",
        order_by: [asc: t.position]
    )
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

  defp writeback_passed(%TaskRun{} = run) do
    task = Repo.get(Dran.Task, run.task_id)

    if task && task.status != "done" do
      # Reuses the real update path: status change → goal recompute +
      # recurrence automation + board broadcast (Snippet 3).
      Dran.Tasks.update_task(task, %{status: "done"})
    end

    :ok
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

    updated =
      session
      |> GoalSession.changeset(%{status: status, finished_at: DateTime.utc_now()})
      |> Repo.update()

    case updated do
      {:ok, %GoalSession{} = closed} ->
        Dran.Goals.recompute_progress(Repo.get(Dran.Goal, closed.goal_id))
        broadcast_session_change(closed, :closed)

      _ ->
        :ok
    end
  end

  # Decision 7: `passed` when everything ended passed/skipped, `failed`
  # otherwise. With retries, the LATEST attempt per task decides — a failed
  # attempt superseded by a passed retry does not doom the session.
  defp session_outcome(session_id) do
    latest =
      Repo.all(
        from r in TaskRun,
          where: r.session_id == ^session_id,
          select: {r.task_id, r.attempt, r.status}
      )
      |> Enum.reduce(%{}, fn {task_id, attempt, status}, acc ->
        case Map.get(acc, task_id) do
          {best_attempt, _} when best_attempt >= attempt -> acc
          _ -> Map.put(acc, task_id, {attempt, status})
        end
      end)

    all_passed? =
      latest != %{} and
        Enum.all?(latest, fn {_task_id, {_attempt, status}} ->
          status in ~w(passed skipped)
        end)

    if all_passed?, do: "passed", else: "failed"
  end

  defp build_retry(%TaskRun{} = run, new_attempt) do
    %TaskRun{}
    |> TaskRun.changeset(%{
      session_id: run.session_id,
      task_id: run.task_id,
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
