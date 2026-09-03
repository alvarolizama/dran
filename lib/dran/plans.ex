defmodule Dran.Plans do
  @moduledoc """
  The Plans context — CRUD for plans (`Dran.Plan`) and steps (`Dran.Step`).

  Leaf context: depends only on Repo + its schemas. Definition layer only:
  no sessions, no runs, no anti-cycle logic (wave C) — step→step `depends_on`
  edges are created by the backfill migration, not here.

  Conventions follow `Dran.Goals`: binary-id PKs with read_after_writes,
  `(workspace_id, slug)` unique per resource, steps listed by `position`.
  """

  import Ecto.Query, warn: false
  import Ecto.Changeset, only: [get_change: 2, put_change: 3]

  alias Dran.Repo
  alias Dran.Plan
  alias Dran.Step

  # ──────────────────────────────────────────────────────────────────────────
  # Plan CRUD
  # ──────────────────────────────────────────────────────────────────────────

  @doc "List plans from the plans table"
  def list_plans(workspace_id) when is_binary(workspace_id) do
    Repo.all(
      from p in Plan,
        where: p.workspace_id == ^workspace_id,
        order_by: [asc: p.title]
    )
  end

  @doc "Get a plan by id, raises if not found"
  def get_plan!(id), do: Repo.get!(Plan, id)

  @doc "Get a plan by slug within a workspace, returns nil if not found"
  def get_plan_by_slug(slug, workspace_id) when is_binary(slug) and is_binary(workspace_id) do
    Repo.one(from p in Plan, where: p.slug == ^slug and p.workspace_id == ^workspace_id)
  end

  @doc "Build a changeset for a plan (for LiveView forms)"
  def change_plan(%Plan{} = plan, attrs \\ %{}) do
    Plan.changeset(plan, attrs)
  end

  @doc "Create a new plan"
  def create_plan(attrs) do
    %Plan{}
    |> Plan.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Update an existing plan"
  def update_plan(%Plan{} = plan, attrs) do
    plan
    |> Plan.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Delete a plan. Refuses (and returns `{:error, :has_sessions}`) when the
  plan has any goal session — sessions snapshot the plan topology and
  deleting the plan under them would break history.
  """
  def delete_plan(%Plan{} = plan) do
    if session_count(plan) > 0 do
      {:error, :has_sessions}
    else
      Repo.delete(plan)
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Step CRUD
  # ──────────────────────────────────────────────────────────────────────────

  @doc "List steps of a plan, ordered by position (then inserted_at for stability)"
  def list_steps(%Plan{} = plan) do
    Repo.all(
      from s in Step,
        where: s.plan_id == ^plan.id,
        order_by: [asc: s.position, asc: s.inserted_at]
    )
  end

  @doc "Get a step by id, raises if not found"
  def get_step!(id), do: Repo.get!(Step, id)

  @doc "Build a changeset for a step (for LiveView forms)"
  def change_step(%Step{} = step, attrs \\ %{}) do
    Step.changeset(step, attrs)
  end

  @doc """
  Create a step in a plan, appended at the end: position = max+100 (gap-based
  convention, same as the board).
  """
  def create_step(%Plan{} = plan, attrs) do
    attrs = for {k, v} <- attrs, into: %{}, do: {to_string(k), v}

    %Step{}
    |> Step.changeset(
      attrs
      |> Map.put("plan_id", plan.id)
      |> Map.put_new("workspace_id", plan.workspace_id)
    )
    |> put_append_position(plan)
    |> Repo.insert()
  end

  @doc "Update an existing step"
  def update_step(%Step{} = step, attrs) do
    step
    |> Step.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Delete a step. Refuses (and returns `{:error, :has_open_runs}`) when the
  step has open runs — an in-flight run materializing this step (wave B)
  must not lose its definition mid-execution.
  """
  def delete_step(%Step{} = step) do
    if open_run_count(step) > 0 do
      {:error, :has_open_runs}
    else
      Repo.delete(step)
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Private
  # ──────────────────────────────────────────────────────────────────────────

  defp put_append_position(changeset, plan) do
    if get_change(changeset, :position) do
      changeset
    else
      max = Repo.aggregate(from(s in Step, where: s.plan_id == ^plan.id), :max, :position)
      put_change(changeset, :position, (max || 0) + 100)
    end
  end

  defp session_count(%Plan{} = plan) do
    # goal_sessions are goal-keyed since F1 (goal_id, no plan_id yet — F2
    # re-points sessions to plans). The guard queries plan_id when the
    # column exists; until then no plan can be referenced by a session and
    # deletion is allowed (held open as an explicit branch, per the packet).
    if Enum.member?(Dran.GoalSession.__schema__(:fields), :plan_id) do
      Repo.aggregate(from(s in Dran.GoalSession, where: s.plan_id == ^plan.id), :count)
    else
      0
    end
  end

  defp open_run_count(%Step{} = step) do
    # task_runs key on task_id since F1 (step_id arrives in wave B when runs
    # re-point to steps). Same pattern: query step_id when the column exists.
    if Enum.member?(Dran.TaskRun.__schema__(:fields), :step_id) do
      Repo.aggregate(
        from(r in Dran.TaskRun, where: r.step_id == ^step.id and r.status in ^~w(pending in_flight)),
        :count
      )
    else
      0
    end
  end
end