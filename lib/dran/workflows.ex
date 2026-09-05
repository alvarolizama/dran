defmodule Dran.Workflows do
  @moduledoc """
  The Workflows context — CRUD for workflows (`Dran.Workflow`) and steps
  (`Dran.Step`).

  Leaf context: depends only on Repo, its schemas and `Dran.Contracts`
  (the cycle guard reused by `link_step_between/3`). Definition layer
  only: no sessions, no runs (that is `Dran.Executions`). The goal link
  is optional navigation (`goal_id` nullable FK) — `list_by_goal/1`
  powers the "Workflows vinculados" section of GoalLive.

  Conventions follow `Dran.Goals`: binary-id PKs with read_after_writes,
  `(workspace_id, slug)` unique per resource, steps listed by `position`.
  """

  import Ecto.Query, warn: false
  import Ecto.Changeset, only: [get_change: 2, put_change: 3]

  alias Dran.Repo
  alias Dran.Relation
  alias Dran.Contracts
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

  ## Options

  - `:after_step_id` — id of an existing step of the SAME workflow (already
    authorized by the caller). When set, the new step gets a `depends_on`
    edge to it in the SAME transaction: a failed edge rolls the step back,
    so the UI never shows a step that ignored its requested placement.
  """
  def create_step(%Workflow{} = workflow, attrs, opts \\ []) do
    attrs = for {k, v} <- attrs, into: %{}, do: {to_string(k), v}

    changeset =
      %Step{}
      |> Step.changeset(
        attrs
        |> Map.put("workflow_id", workflow.id)
        |> Map.put_new("workspace_id", workflow.workspace_id)
      )
      |> put_append_position(workflow)

    Repo.transaction(fn ->
      case Repo.insert(changeset) do
        {:ok, step} ->
          case Keyword.fetch(opts, :after_step_id) do
            {:ok, prereq_id} ->
              link_dependency!(step, Repo.get!(Step, prereq_id))
              step

            :error ->
              step
          end

        # Rollback surfaces the changeset (constraint errors included) as
        # {:error, changeset} — the same contract as a plain Repo.insert.
        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  defp link_dependency!(step, prereq) do
    %Relation{}
    |> Relation.changeset(%{
      source_id: step.id,
      source_type: "step",
      target_id: prereq.id,
      target_type: "step",
      relation_type: "depends_on"
    })
    |> Repo.insert!(on_conflict: :nothing)
  end

  # Swap `dependent → old_prereq` for `dependent → new_prereq` (the middle
  # node). An update — not delete+insert — keeps the relation row id stable.
  # A pre-existing `dependent → new_prereq` edge (diamond: the middle step
  # already depends on the prereq) makes the UPDATE collide with the unique
  # (source_id, target_id, relation_type) index — the end state is already
  # what the caller wants, so the stale row is DELETED instead of rewired.
  # The unique constraint stays as the race backstop.
  defp replace_prereq(dependent, old_prereq, new_prereq) do
    case Repo.one(relation_query(dependent, old_prereq)) do
      nil ->
        {:error, :missing_edge}

      relation ->
        if Repo.exists?(relation_query(dependent, new_prereq)) do
          Repo.delete(relation)
        else
          relation
          |> Relation.changeset(%{target_id: new_prereq.id})
          |> Repo.update()
        end
    end
  end

  @doc """
  Insert a NEW step in the middle of an edge: prereq → new → dependent.

  Same transaction as `create_step/3` (`:after_step_id`): the new step is
  created AND rewired atomically — the old `prereq → dependent` edge is
  replaced by `dependent → new` and `new → prereq`. Any failure rolls the
  whole insert back, so the graph never loses an edge without gaining the
  step. The new step inherits the dependent's canvas position (slides into
  its slot; the LV nudges the dependent aside afterwards).

  Both endpoints must already be steps of THIS workflow (authorized by the
  caller — canvas params are forgeable). `{:error, :missing_edge}` when the
  `prereq → dependent` edge does not exist (forged or stale pair); the
  graph is left untouched.
  """
  def insert_step_between(%Workflow{} = workflow, %Step{} = dependent, %Step{} = prereq, attrs) do
    if edge_between?(dependent, prereq) do
      attrs = put_unique_step_slug(attrs, workflow)

      changeset =
        %Step{}
        |> Step.changeset(
          attrs
          |> Map.put("workflow_id", workflow.id)
          |> Map.put_new("workspace_id", workflow.workspace_id)
        )
        |> put_append_position(workflow)

      Repo.transaction(fn ->
        case Repo.insert(changeset) do
          {:ok, step} ->
            link_dependency!(step, prereq)

            case replace_prereq(dependent, prereq, step) do
              {:ok, _} -> step
              {:error, :missing_edge} -> Repo.rollback(:missing_edge)
              # Unique-index race backstop (pre-checked above): typed error,
              # never a CaseClause crash.
              {:error, %Ecto.Changeset{}} -> Repo.rollback(:edge_taken)
            end

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)
    else
      {:error, :missing_edge}
    end
  end

  @doc """
  Place an EXISTING step of the workflow in the middle of an edge:
  prereq → existing → dependent.

  Atomically rewires the old edge (a `Repo.update`, the relation row keeps
  its id) and adds the `existing → prereq` edge (`on_conflict: :nothing`,
  so a pre-existing edge is a no-op success). Returns `{:error, :invalid}`
  when the middle step IS one of the endpoints (self-edge) and
  `{:error, :cycle}` (via `Contracts.add_dependency`) with everything
  rolled back.
  """
  def link_step_between(%Step{} = dependent, %Step{} = prereq, %Step{} = middle) do
    if middle.id in [dependent.id, prereq.id] do
      {:error, :invalid}
    else
      Repo.transaction(fn ->
        case replace_prereq(dependent, prereq, middle) do
          {:ok, _} -> :rewired
          {:error, :missing_edge} -> Repo.rollback(:missing_edge)
          # Unique-index race backstop (pre-checked above): typed error,
          # never a CaseClause crash.
          {:error, %Ecto.Changeset{}} -> Repo.rollback(:edge_taken)
        end

        case Contracts.add_dependency(middle, prereq) do
          {:ok, _} -> :linked
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp edge_between?(dependent, prereq) do
    Repo.exists?(relation_query(dependent, prereq))
  end

  # Steps need a workspace-unique slug — the changeset requires it and the
  # DB enforces (workspace_id, slug). When the caller does not pass one,
  # derive it from the title and suffix it while it collides within the
  # workflow's steps. Called INSIDE no transaction: the candidate check and
  # the insert race in theory, the unique constraint is the backstop.
  defp put_unique_step_slug(attrs, workflow) do
    attrs = for {k, v} <- attrs, into: %{}, do: {to_string(k), v}
    base = attrs["slug"] || Dran.Slug.slugify(attrs["title"] || "paso")

    taken =
      from(s in Step,
        where: s.workflow_id == ^workflow.id,
        select: s.slug
      )

    taken = Repo.all(taken) |> MapSet.new()

    if MapSet.member?(taken, base) do
      Map.put(attrs, "slug", "#{base}-#{Ecto.UUID.generate() |> String.slice(0, 6)}")
    else
      Map.put(attrs, "slug", base)
    end
  end

  defp relation_query(dependent, prereq) do
    from r in Relation,
      where:
        r.source_id == ^dependent.id and r.source_type == "step" and
          r.target_id == ^prereq.id and r.target_type == "step" and
          r.relation_type == "depends_on"
  end

  @doc "Update an existing step"
  def update_step(%Step{} = step, attrs) do
    step
    |> Step.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Persist the canvas position of a step: `meta["pos"] = %{"x" => x, "y" => y}`.

  Coordinates are stage pixels (already grid-snapped by the client). The
  position is presentation state only — execution truth stays in the
  `depends_on` relations — so callers treat failures as cosmetic (the LV
  event is silent by design).
  """
  def move_step(%Step{} = step, x, y)
      when is_integer(x) and is_integer(y) and x >= 0 and y >= 0 do
    # Re-read: the caller's struct may be stale (a contract edited after it
    # was loaded) — meta.pos merges over the CURRENT meta, never replaces it.
    step = Repo.get!(Step, step.id)
    meta = step.meta || %{}

    step
    |> Step.changeset(%{"meta" => Map.put(meta, "pos", %{"x" => x, "y" => y})})
    |> Repo.update()
  end

  @doc """
  Persist canvas positions for many steps in one transaction:
  `%{step_id => {x, y}}`.

  Called after a card drag: the LV always sends the COMPLETE map (the
  layout it currently renders, with the dragged card moved), which keeps
  the free layout all-or-nothing even for the very first drag. Steps not
  in the map are left untouched; other meta keys (contract) preserved.
  """
  def persist_positions(%Workflow{} = workflow, positions) when is_map(positions) do
    Repo.transaction(fn ->
      workflow
      |> list_steps()
      |> Enum.each(fn step ->
        case Map.get(positions, step.id) do
          {x, y} when is_integer(x) and is_integer(y) ->
            meta = Map.put(step.meta || %{}, "pos", %{"x" => x, "y" => y})
            step |> Step.changeset(%{"meta" => meta}) |> Repo.update!()

          nil ->
            :ok
        end
      end)
    end)
  end

  @doc """
  Clear every step's canvas position (`meta["pos"]`) so the workflow falls
  back to the automatic topological layout (levels). Used by the canvas
  "ordenar por nivel" action; `meta.contract` is preserved.
  """
  def repack_layout(%Workflow{} = workflow) do
    Repo.transaction(fn ->
      workflow
      |> list_steps()
      |> Enum.each(fn step ->
        meta = Map.delete(step.meta || %{}, "pos")

        step
        |> Step.changeset(%{"meta" => meta})
        |> Repo.update!()
      end)
    end)
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
