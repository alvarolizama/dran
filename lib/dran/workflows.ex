defmodule Dran.Workflows do
  @moduledoc """
  The Workflows context — CRUD for workflows (`Dran.Workflow`) and steps
  (`Dran.Step`).

  Leaf context: depends only on Repo + its schemas. Definition layer
  only: no sessions, no runs (that is `Dran.Executions`). The goal link
  is optional navigation (`goal_id` nullable FK) — `list_by_goal/1`
  powers the "Workflows vinculados" section of GoalLive.

  Conventions follow `Dran.Goals`: binary-id PKs with read_after_writes,
  `(workspace_id, slug)` unique per resource, steps listed by `position`.
  """

  import Ecto.Query, warn: false
  import Ecto.Changeset, only: [get_change: 2, put_change: 3]

  alias Dran.Repo
  alias Dran.Workflow
  alias Dran.Step

  # ──────────────────────────────────────────────────────────────────────────
  # Workflow CRUD
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  List workflows of a workspace.

  By default lists unarchived workflows (status `draft` + `active`).
  Options:

    * `:archived` — `true` lists ONLY archived workflows (default `false`)
    * `:kind` — kind filter: a list of slugs (`["evergreen", "one_shot"]`)
      or a single slug string; `[]`/nil lists every kind
    * `:status` — status filter for the non-archived list (`["draft"]`,
      `["active"]` or both); `[]`/nil lists both

  The WorkflowsLive index drives both filters from URL state, so filtered
  views are shareable (same convention as pages kind filters).
  """
  def list_workflows(workspace_id, opts \\ []) when is_binary(workspace_id) do
    archived = Keyword.get(opts, :archived, false)
    kinds = kinds_filter(Keyword.get(opts, :kind, []))
    statuses = statuses_filter(Keyword.get(opts, :status, []))

    query = from w in Workflow, where: w.workspace_id == ^workspace_id

    query =
      if archived do
        from w in query, where: w.status == "archived"
      else
        base = from w in query, where: w.status != "archived"

        case statuses do
          [] -> base
          statuses -> from w in base, where: w.status in ^statuses
        end
      end

    query =
      case kinds do
        [] -> query
        kinds -> from w in query, where: w.kind in ^kinds
      end

    Repo.all(from w in query, order_by: [asc: w.status, asc: w.title])
  end

  # Keep queries honest: only the two registered kinds ever reach the SQL.
  defp kinds_filter(kinds) when is_list(kinds),
    do: Enum.filter(kinds, &(&1 in ["evergreen", "one_shot"]))

  defp kinds_filter(kind) when kind in ["evergreen", "one_shot"], do: [kind]
  defp kinds_filter(_), do: []

  # Status filter for the non-archived list: valid statuses minus "archived"
  # (the archived view is orthogonal — `archived: true` owns that).
  defp statuses_filter(statuses) when is_list(statuses),
    do: Enum.filter(statuses, &(&1 in ["draft", "active"]))

  defp statuses_filter(status) when status in ["draft", "active"], do: [status]
  defp statuses_filter(_), do: []

  @doc "List workflows optionally linked to a goal (GoalLive section)"
  def list_by_goal(%Dran.Goal{} = goal) do
    Repo.all(
      from w in Workflow,
        where: w.goal_id == ^goal.id,
        order_by: [asc: w.title]
    )
  end

  @doc "Get a workflow by id, raises if not found"
  def get_workflow!(id), do: Repo.get!(Workflow, id)

  @doc "Get a workflow by slug within a workspace, returns nil if not found"
  def get_workflow_by_slug(slug, workspace_id)
      when is_binary(slug) and is_binary(workspace_id) do
    Repo.one(from w in Workflow, where: w.slug == ^slug and w.workspace_id == ^workspace_id)
  end

  @doc "Build a changeset for a workflow (for LiveView forms)"
  def change_workflow(%Workflow{} = workflow, attrs \\ %{}) do
    Workflow.changeset(workflow, attrs)
  end

  @doc "Create a new workflow"
  def create_workflow(attrs) do
    %Workflow{}
    |> Workflow.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Update an existing workflow"
  def update_workflow(%Workflow{} = workflow, attrs) do
    workflow
    |> Workflow.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Archive a workflow — `status: \"archived\"`. Evergreen workflows with
  open in-flight sessions are REFUSED (`{:error, :has_open_sessions}`):
  archiving is for definitions that stopped being used and leaving a live
  session under an archived definition is a contradiction (executions run
  on the snapshot, but the definition is gone from the active lists).

  Broadcasts `{:workflow_changed, :archived, workflow}` on the workspace
  topic so other open tabs update (cards, linked-goals section).
  """
  def archive_workflow(%Workflow{status: "archived"} = workflow),
    do: {:ok, workflow}

  def archive_workflow(%Workflow{} = workflow) do
    if has_open_sessions?(workflow) do
      {:error, :has_open_sessions}
    else
      with {:ok, workflow} <- update_workflow(workflow, %{"status" => "archived"}) do
        broadcast_workflow_change(workflow, :archived)
        {:ok, workflow}
      end
    end
  end

  @doc """
  Unarchive a workflow — `status` back to `\"draft\"` (never auto-active:
  activation is an explicit decision). No-op when already unarchived.
  """
  def unarchive_workflow(%Workflow{status: "archived"} = workflow) do
    with {:ok, workflow} <- update_workflow(workflow, %{"status" => "draft"}) do
      broadcast_workflow_change(workflow, :unarchived)
      {:ok, workflow}
    end
  end

  def unarchive_workflow(%Workflow{} = workflow), do: {:ok, workflow}

  @doc "True when the workflow has at least one session still in flight."
  def has_open_sessions?(%Workflow{} = workflow) do
    Repo.exists?(
      from s in Dran.WorkflowSession,
        where: s.workflow_id == ^workflow.id and s.status == "in_flight"
    )
  end

  @doc false
  def broadcast_workflow_change(%Workflow{workspace_id: nil}, _action), do: :ok

  def broadcast_workflow_change(%Workflow{} = workflow, action) do
    Phoenix.PubSub.broadcast(
      Dran.PubSub,
      "workspace:#{workflow.workspace_id}",
      {:workflow_changed, action, workflow}
    )
  rescue
    # PubSub may not be running during release tasks / seeds — the broadcast
    # is a UI notification, not a data-integrity concern.
    ArgumentError -> :ok
  end

  @doc """
  Delete a workflow. Refuses (and returns `{:error, :has_sessions}`) when
  it has any session — sessions snapshot the topology and deleting the
  workflow under them would break history.
  """
  def delete_workflow(%Workflow{} = workflow) do
    if session_count(workflow) > 0 do
      {:error, :has_sessions}
    else
      Repo.transaction(fn ->
        # steps die with the FK cascade; their depends_on edges (polymorphic
        # relations, no FK) must go by hand
        step_ids = Repo.all(from s in Step, where: s.workflow_id == ^workflow.id, select: s.id)

        if step_ids != [] do
          Repo.delete_all(
            from r in Dran.Relation,
              where:
                (r.source_id in ^step_ids and r.source_type == "step") or
                  (r.target_id in ^step_ids and r.target_type == "step")
          )
        end

        Repo.delete!(workflow)
      end)
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Step CRUD
  # ──────────────────────────────────────────────────────────────────────────

  @doc "List steps of a workflow, ordered by position (then inserted_at for stability)"
  def list_steps(%Workflow{} = workflow) do
    Repo.all(
      from s in Step,
        where: s.workflow_id == ^workflow.id,
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
  Create a step in a workflow, appended at the end: position = max+100
  (gap-based convention, same as the board).
  """
  def create_step(%Workflow{} = workflow, attrs) do
    attrs = for {k, v} <- attrs, into: %{}, do: {to_string(k), v}

    %Step{}
    |> Step.changeset(
      attrs
      |> Map.put("workflow_id", workflow.id)
      |> Map.put_new("workspace_id", workflow.workspace_id)
    )
    |> put_append_position(workflow)
    |> Repo.insert()
  end

  @doc "Update an existing step"
  def update_step(%Step{} = step, attrs) do
    step
    |> Step.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Delete a step. Refuses when:
  - `{:error, :has_open_runs}` — the step has open runs (an in-flight run
    materializing this step must not lose its definition mid-execution);
  - `{:error, :referenced_by_open_session}` — the step appears in the
    frozen `snapshot` of an OPEN session: deleting it would cascade its
    runs away via FK and permanently block the dependents of that pass
    (snapshots are the session's frozen truth).
  Deletes its step→step `depends_on` edges (polymorphic relations have
  no FK cascade) in the same transaction.
  """
  def delete_step(%Step{} = step) do
    if open_run_count(step) > 0 do
      {:error, :has_open_runs}
    else
      if referenced_by_open_session?(step) do
        {:error, :referenced_by_open_session}
      else
        Repo.transaction(fn ->
          Repo.delete_all(
            from r in Dran.Relation,
              where:
                (r.source_id == ^step.id and r.source_type == "step") or
                  (r.target_id == ^step.id and r.target_type == "step")
          )

          Repo.delete!(step)
        end)
      end
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Private
  # ──────────────────────────────────────────────────────────────────────────

  defp put_append_position(changeset, %Workflow{} = workflow) do
    if get_change(changeset, :position) do
      changeset
    else
      max =
        Repo.aggregate(from(s in Step, where: s.workflow_id == ^workflow.id), :max, :position)

      put_change(changeset, :position, (max || 0) + 100)
    end
  end

  defp session_count(%Workflow{} = workflow) do
    Repo.aggregate(from(s in Dran.WorkflowSession, where: s.workflow_id == ^workflow.id), :count)
  end

  defp open_run_count(%Step{} = step) do
    Repo.aggregate(
      from(r in Dran.Run,
        where: r.step_id == ^step.id and r.status in ^~w(pending in_flight)
      ),
      :count
    )
  end

  # The step's id appears in the frozen snapshot (steps or edges) of any
  # OPEN session — the pass was opened against that topology.
  defp referenced_by_open_session?(%Step{} = step) do
    step_json = Jason.encode!(%{id: step.id})
    edge_json = Jason.encode!([step.id])

    Repo.exists?(
      from s in Dran.WorkflowSession,
        where: s.status == "in_flight",
        where:
          fragment("?->'steps' @> ?", s.snapshot, ^step_json) or
            fragment("?->'edges' @> ?", s.snapshot, ^edge_json)
    )
  end
end
