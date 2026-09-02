defmodule Dran.Tasks.Automation do
  @moduledoc """
  Task automations: recurrence cloning and SLA/WIP reporting.

  ## Recurrence

  When a task with `recurrence != "none"` reaches a terminal status
  (done/cancelled), `handle_completion/1` clones it back to the board with
  the next due date. Pure date arithmetic — no RRULE dependency:

      daily   → due_date + 1 day
      weekly  → due_date + 7 days
      monthly → due_date shifted 1 month (calendar-aware via Date.add with
                 month clamping via :calendar.last_day_of_the_month)

  The clone keeps title/body/priority/recurrence/meta/links (part_of
  relations are copied so goal progress tracks the new occurrence) and gets
  a fresh slug (`<base>-<n>` where n grows until unique).

  Called from `Dran.Tasks.move_task/3` and `update_task/2` via
  `maybe_recur/1` — completion through any surface (board, MCP, API)
  triggers the clone.

  ## SLA / WIP sweep (`sweep/0`)

  Quantum job (see `Dran.Jobs`): writes one log report listing

    - overdue tasks (due_date < today, not done/cancelled)
    - stale in_progress (updated_at older than 7 days)
    - WIP breaches (in_progress count above the per-workspace limit in
      Settings, default unlimited)

  Report type: "log", same second-citizen convention as other jobs.
  """

  import Ecto.Query

  alias Dran.{Repo, Task, Tasks}

  @stale_days 7

  # ──────────────────────────────────────────────────────────────────────────
  # Recurrence — called on task completion
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Clone a completed recurring task back to the board with the next due date.

  No-op when the task is not recurring or not in a terminal status.
  Returns `{:ok, %Task{}}` (the clone), `{:ok, :not_recurring}`, or
  `{:error, reason}`.
  """
  def handle_completion(%Task{} = task) do
    cond do
      task.recurrence in [nil, "none"] ->
        {:ok, :not_recurring}

      task.status not in ~w(done cancelled) ->
        {:ok, :not_recurring}

      true ->
        clone_recurring(task)
    end
  end

  defp clone_recurring(%Task{} = task) do
    next_due = next_due_date(task.due_date || Date.utc_today(), task.recurrence)

    attrs = %{
      "workspace_id" => task.workspace_id,
      "title" => task.title,
      "slug" => next_slug(task.slug, task.workspace_id),
      "body" => task.body,
      "status" => "backlog",
      "priority" => task.priority,
      "due_date" => next_due,
      "recurrence" => task.recurrence,
      "meta" => task.meta,
      "assignee_actor_id" => task.assignee_actor_id,
      "created_by" => "automation:recurrence"
    }

    with {:ok, clone} <- Tasks.create_task(attrs),
         :ok <- copy_links(task, clone) do
      {:ok, clone}
    end
  end

  # Copy part_of relations (goal/page links) from the completed occurrence
  # to its clone, so goal progress keeps tracking the series.
  defp copy_links(%Task{} = from, %Task{} = to) do
    links =
      Repo.all(
        from r in Dran.Relation,
          where: r.source_id == ^from.id and r.source_type == "task"
      )

    for link <- links do
      Dran.Knowledge.create_relation(%{
        source_id: to.id,
        source_type: "task",
        target_id: link.target_id,
        target_type: link.target_type,
        relation_type: link.relation_type
      })
    end

    :ok
  end

  defp next_slug(base, workspace_id) do
    # todo-rutina → todo-rutina-2 → todo-rutina-3 …
    root = Regex.replace(~r/-\d+$/, base, "")

    Stream.iterate(2, &(&1 + 1))
    |> Enum.find_value(fn n ->
      candidate = "#{root}-#{n}"
      if is_nil(Tasks.get_task_by_slug(candidate, workspace_id)), do: candidate
    end)
  end

  @doc "Next due date for a recurrence, calendar-aware."
  def next_due_date(%Date{} = from, "daily"), do: Date.add(from, 1)
  def next_due_date(%Date{} = from, "weekly"), do: Date.add(from, 7)

  def next_due_date(%Date{} = from, "monthly") do
    # Month shift with day clamping (Jan 31 → Feb 28/29)
    next_month =
      if from.month == 12 do
        Date.new!(from.year + 1, 1, 1)
      else
        Date.new!(from.year, from.month + 1, 1)
      end

    last_day = :calendar.last_day_of_the_month(next_month.year, next_month.month)
    day = min(from.day, last_day)
    Date.new!(next_month.year, next_month.month, day)
  end

  def next_due_date(%Date{} = from, _), do: Date.add(from, 7)

  # ──────────────────────────────────────────────────────────────────────────
  # SLA / WIP sweep — Quantum job body
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Sweep all workspaces for SLA/WIP anomalies. Returns a summary map used by
  the Quantum job to write its log report.
  """
  def sweep do
    overdue = list_overdue()
    stale = list_stale_in_progress()
    wip = wip_breaches()

    %{
      overdue: overdue,
      stale: stale,
      wip_breaches: wip,
      total_issues: length(overdue) + length(stale) + length(wip)
    }
  end

  def list_overdue do
    today = Date.utc_today()

    Repo.all(
      from t in Task,
        where:
          t.archived == false and
            not is_nil(t.due_date) and
            t.due_date < ^today and
            t.status not in ~w(done cancelled),
        order_by: [asc: t.due_date],
        preload: [:workspace]
    )
  end

  def list_stale_in_progress do
    cutoff = DateTime.add(DateTime.utc_now(), -@stale_days, :day)

    Repo.all(
      from t in Task,
        where:
          t.archived == false and
            t.status == "in_progress" and
            t.updated_at < ^cutoff,
        order_by: [asc: t.updated_at],
        preload: [:workspace]
    )
  end

  @doc """
  Workspaces whose in_progress count exceeds their WIP limit.

  The limit lives in Settings as `task_wip_limit` (integer, 0/absent =
  unlimited). Returns `[%{workspace: ws, count: n, limit: lim}]`.
  """
  def wip_breaches do
    counts =
      Repo.all(
        from t in Task,
          where: t.archived == false and t.status == "in_progress",
          group_by: t.workspace_id,
          select: {t.workspace_id, count(t.id)}
      )

    for {workspace_id, count} <- counts,
        limit = wip_limit_for(workspace_id),
        not is_nil(limit) and limit > 0 and count > limit,
        ws = Repo.get(Dran.Workspace, workspace_id) do
      %{workspace: ws, count: count, limit: limit}
    end
  end

  defp wip_limit_for(workspace_id) do
    # Settings is global (no per-workspace scoping yet); the WIP limit key
    # can optionally carry a per-workspace override via "ws:<id>" map form.
    case Dran.Settings.get("task_wip_limit") do
      %{} = per_ws ->
        Map.get(per_ws, workspace_id)

      value when is_binary(value) ->
        String.to_integer(value)

      value when is_integer(value) ->
        value

      _ ->
        nil
    end
  rescue
    # Settings table may not exist yet in fresh boots — WIP check is
    # advisory, degrade to "no limit".
    _ -> nil
  end

  @doc """
  Quantum entrypoint — sweep + report body in one call. Returns a markdown
  string so `Dran.Jobs.execute/3` records it verbatim as the run result.
  """
  @spec run_scheduled() :: String.t()
  def run_scheduled do
    sweep() |> sweep_report_body()
  end

  @doc "Markdown body for the sweep report (Dran.Jobs log convention)."
  def sweep_report_body(%{} = sweep_result) do
    """
    # Task SLA / WIP sweep

    ## Overdue (#{length(sweep_result.overdue)})

    #{for t <- sweep_result.overdue, do: "- **#{t.title}** (#{t.workspace.slug}) — due #{t.due_date}"}

    ## Stale in_progress > #{@stale_days}d (#{length(sweep_result.stale)})

    #{for t <- sweep_result.stale, do: "- **#{t.title}** (#{t.workspace.slug}) — last update #{Calendar.strftime(t.updated_at, "%Y-%m-%d")}"}

    ## WIP breaches (#{length(sweep_result.wip_breaches)})

    #{for b <- sweep_result.wip_breaches, do: "- **#{b.workspace.name}** — #{b.count}/#{b.limit} in_progress"}
    """
    |> String.trim()
  end
end
