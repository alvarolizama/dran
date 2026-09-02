defmodule Dran.Tasks do
  @moduledoc """
  The Tasks context — CRUD and board operations for `Dran.Task`.

  Tasks are independent entities (standalone by default). Links to goals and
  pages are opt-in via `Dran.Relation` (W2 adds "task" as a node type).

  ## Board operations

  `list_board/1` returns tasks grouped by status for kanban rendering.
  `move_task/3` moves a task between columns with optimistic locking and
  re-numbers positions to maintain gap-based ordering.

  ## Slug generation

  Uses `Dran.Slug.slugify/1` (pure) + an internal uniqueness check against
  the tasks table (not `Knowledge.get_page_by_slug`, which checks pages).
  """

  import Ecto.Query, warn: false

  alias Dran.{Repo, Task, Slug, Knowledge}

  # ──────────────────────────────────────────────────────────────────────────
  # Listing
  # ──────────────────────────────────────────────────────────────────────────

  @doc "List tasks in a workspace, optionally filtered by status or assignee."
  def list_tasks(opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)
    status = Keyword.get(opts, :status)
    assignee_id = Keyword.get(opts, :assignee_id)
    archived = Keyword.get(opts, :archived, false)
    limit = Keyword.get(opts, :limit, 500)

    query =
      from(t in Task,
        where: t.archived == ^archived,
        order_by: [asc: t.position],
        limit: ^limit
      )

    query =
      if workspace_id do
        where(query, [t], t.workspace_id == ^workspace_id)
      else
        query
      end

    query =
      if status do
        where(query, [t], t.status == ^status)
      else
        query
      end

    query =
      if assignee_id do
        where(query, [t], t.assignee_id == ^assignee_id)
      else
        query
      end

    Repo.all(query)
  end

  @doc """
  List tasks grouped by status for board rendering.

  Returns a map: `%{"backlog" => [task, ...], "todo" => [...], ...}`.
  Only non-archived tasks in the given workspace. Every status key is
  present even when empty (the board always renders all columns).
  """
  def list_board(workspace_id) when is_binary(workspace_id) do
    tasks =
      from(t in Task,
        where: t.workspace_id == ^workspace_id and t.archived == false,
        order_by: [asc: t.position]
      )
      |> Repo.all()
      |> Repo.preload(:assignee_actor)

    Task.statuses()
    |> Map.new(fn status ->
      {status, Enum.filter(tasks, &(&1.status == status))}
    end)
  end

  @doc "Get a task by id with its assignee preloaded, returns nil if not found."
  def get_task(id) do
    Repo.get(Task, id) |> Repo.preload(:assignee_actor)
  end

  @doc "Get a task by slug within a workspace."
  def get_task_by_slug(slug, workspace_id) when is_binary(slug) and is_binary(workspace_id) do
    Repo.one(from t in Task, where: t.slug == ^slug and t.workspace_id == ^workspace_id)
  end

  @doc "Build a changeset for a task (for LiveView forms)."
  def change_task(%Task{} = _task, attrs \\ %{}) do
    Task.create_changeset(attrs)
  end

  # ──────────────────────────────────────────────────────────────────────────
  # CRUD
  # ──────────────────────────────────────────────────────────────────────────

  @doc "Create a new task. Generates a unique slug if none provided."
  def create_task(attrs) do
    attrs =
      attrs
      |> ensure_slug()
      |> default_owner_fields()

    Task.create_changeset(Map.new(attrs, fn {k, v} -> {to_string(k), v} end))
    |> Repo.insert()
    |> tap(fn
      {:ok, task} -> broadcast_task_change(task, :created)
      _ -> :ok
    end)
  end

  @doc "Update a task."
  def update_task(%Task{} = task, attrs) do
    task
    |> Task.update_changeset(attrs)
    |> Repo.update()
    |> tap(fn
      {:ok, updated} ->
        if status_changed?(task, updated) do
          recompute_linked_goals(updated)
          # Recurring tasks clone themselves on completion.
          Dran.Tasks.Automation.handle_completion(updated)
        end

        broadcast_task_change(updated, :updated)

      _ ->
        :ok
    end)
  end

  defp status_changed?(%Task{status: old}, %Task{status: new}) when old != new, do: true
  defp status_changed?(_, _), do: false

  @doc "Delete a task."
  def delete_task(%Task{} = task) do
    with {:ok, deleted} <- Repo.delete(task) do
      broadcast_task_change(deleted, :deleted)
      {:ok, deleted}
    end
  end

  # Broadcast task changes so open boards refresh in real time (same topic
  # convention as Knowledge.broadcast_page_change, but with a task tuple).
  defp broadcast_task_change(%Task{workspace_id: nil}, _action), do: :ok

  defp broadcast_task_change(%Task{} = task, action) do
    Phoenix.PubSub.broadcast(
      Dran.PubSub,
      "workspace:#{task.workspace_id}",
      {:task_changed, action, task}
    )
  rescue
    # PubSub may not be running during release tasks / seeds — the broadcast
    # is a UI notification, not a data-integrity concern.
    ArgumentError -> :ok
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Opt-in links to goals and pages (polymorphic part_of relations)
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Link a task to a goal (opt-in). Creates a `part_of` relation
  (`source_type: "task"`, `target_type: "goal"`) and recomputes the goal's
  derived progress. Idempotent — the unique index on
  (source_id, target_id, relation_type) absorbs duplicates.
  """
  def link_to_goal(%Task{} = task, %Dran.Goal{} = goal) do
    result =
      Knowledge.create_relation(%{
        source_id: task.id,
        source_type: "task",
        target_id: goal.id,
        target_type: "goal",
        relation_type: "part_of"
      })

    :ok = Dran.Goals.recompute_progress(goal)
    # Linked goals are part of the task's UI state — notify open views
    # (goal detail shows this task under the goal; board shows the chip).
    broadcast_task_change(task, :linked)
    result
  end

  @doc """
  Link a task to a page (opt-in) — e.g. a project or plan note. Creates a
  `part_of` relation (`source_type: "task"`, `target_type: "page"`).
  Idempotent.
  """
  def link_to_page(%Task{} = task, %Dran.Page{} = page) do
    Knowledge.create_relation(%{
      source_id: task.id,
      source_type: "task",
      target_id: page.id,
      target_type: "page",
      relation_type: "part_of"
    })
  end

  @doc """
  Unlink a task from a goal — deletes the `part_of` relation and recomputes
  the goal's progress.
  """
  def unlink_from_goal(%Task{} = task, %Dran.Goal{} = goal) do
    Repo.delete_all(
      from(r in Dran.Relation,
        where:
          r.source_id == ^task.id and r.source_type == "task" and
            r.target_id == ^goal.id and r.target_type == "goal" and
            r.relation_type == "part_of"
      )
    )

    :ok = Dran.Goals.recompute_progress(goal)
    broadcast_task_change(task, :unlinked)
    {:ok, :unlinked}
  end

  @doc """
  List goals linked to a task via `part_of` relations.
  Returns a list of `%Dran.Goal{}`.
  """
  def list_linked_goals(%Task{} = task) do
    Repo.all(
      from g in Dran.Goal,
        join: r in Dran.Relation,
        on:
          r.target_id == g.id and r.target_type == "goal" and
            r.relation_type == "part_of" and r.source_id == ^task.id and
            r.source_type == "task"
    )
  end

  @doc """
  List tasks linked to a goal via `part_of` relations — the inverse of
  `list_linked_goals/1`. Non-archived tasks only, in board order
  (position), with the assignee preloaded for card rendering.
  """
  def list_tasks_for_goal(%Dran.Goal{} = goal) do
    from(t in Task,
      join: r in Dran.Relation,
      on:
        r.source_id == t.id and r.source_type == "task" and
          r.relation_type == "part_of" and r.target_id == ^goal.id and
          r.target_type == "goal",
      where: t.archived == false,
      order_by: [asc: t.position]
    )
    |> Repo.all()
    |> Repo.preload(:assignee_actor)
  end

  @doc """
  Point a task at a goal (or detach it) in one operation — backs the
  detail-panel "Goal" select.

  Switching goals unlinks the previous one(s) first, so a task lives under
  a single goal at a time from the UI's perspective. Both the old and the
  new goal get their derived progress recomputed. `nil` / `""` detaches.

  `current_goals` may carry the task's already-loaded links to avoid a
  redundant query (see `list_linked_goals/1`) — that is `set_goal/3`;
  `set_goal/2` loads them for you.

  The goal must belong to the same workspace as the task; anything else
  returns `{:error, :goal_not_found}`. Idempotent: setting the goal the
  task already has is a no-op that returns the reloaded task.
  """
  def set_goal(%Task{} = task, goal_id) do
    set_goal(task, goal_id, list_linked_goals(task))
  end

  def set_goal(%Task{} = task, goal_id, current_goals) when goal_id in [nil, ""] do
    current_goals = current_goals || list_linked_goals(task)
    :ok = detach_all_goals(task, current_goals)

    {:ok, get_task(task.id)}
  end

  def set_goal(%Task{} = task, goal_id, current_goals) when is_binary(goal_id) do
    current_goals = current_goals || list_linked_goals(task)

    cond do
      not valid_uuid?(goal_id) ->
        {:error, :goal_not_found}

      Enum.any?(current_goals, &(&1.id == goal_id)) ->
        {:ok, get_task(task.id)}

      true ->
        with %Dran.Goal{} = goal <- Dran.Goals.get_goal(goal_id),
             true <- goal.workspace_id == task.workspace_id,
             :ok <- detach_all_goals(task, current_goals),
             {:ok, _relation} <- link_to_goal(task, goal) do
          {:ok, get_task(task.id)}
        else
          nil -> {:error, :goal_not_found}
          false -> {:error, :goal_not_found}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # Forged event params may carry arbitrary binaries; Ecto raises
  # Ecto.Query.CastError on Repo.get/2 with a non-UUID string.
  defp valid_uuid?(value) do
    case Ecto.UUID.cast(value) do
      {:ok, _} -> true
      :error -> false
    end
  end

  # Unlink a task from every goal in the list, recomputing each goal's
  # progress on the way. A failed unlink is an invariant breach — crash.
  defp detach_all_goals(_task, []), do: :ok

  defp detach_all_goals(task, [goal | rest]) do
    {:ok, :unlinked} = unlink_from_goal(task, goal)
    detach_all_goals(task, rest)
  end

  @doc """
  Goals linked to any of the given task ids, in one query — returns
  `%{task_id => [goal, ...]}` (missing keys mean "no linked goals"). Used
  by the board to badge cards without N+1 queries.

  Scoped to `workspace_id`: relations are not FK-enforced to a workspace,
  so an explicit filter guarantees no goal titles leak across workspaces
  (SEC-002 lesson).
  """
  def list_linked_goals_by_ids(task_ids, workspace_id) when is_list(task_ids) do
    from(r in Dran.Relation,
      join: g in Dran.Goal,
      on: g.id == r.target_id,
      where:
        r.source_type == "task" and r.relation_type == "part_of" and
          r.target_type == "goal" and r.source_id in ^task_ids and
          g.workspace_id == ^workspace_id,
      select: {r.source_id, g}
    )
    |> Repo.all()
    |> Enum.group_by(fn {task_id, _goal} -> task_id end, fn {_task_id, goal} -> goal end)
  end

  @doc """
  Creator actor ids for a batch of tasks — `%{task_id => actor_id}` (missing
  keys mean "no id-attributed creator"). Backs the board's assignee filter
  (F7): same batch mechanic as `list_linked_goals_by_ids/2`, no N+1, and
  identity by FK instead of the legacy name-matching convention.
  """
  def list_creator_actor_ids_by_ids(task_ids) when is_list(task_ids) do
    from(t in Task,
      where: t.id in ^task_ids and not is_nil(t.creator_actor_id),
      select: {t.id, t.creator_actor_id}
    )
    |> Repo.all()
    |> Map.new()
  end

  # Recompute derived progress for every goal linked to this task.
  # Called after any status change (move_task/update_task).
  defp recompute_linked_goals(%Task{} = task) do
    for goal <- list_linked_goals(task) do
      Dran.Goals.recompute_progress(goal)
    end

    :ok
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Board move — optimistic lock + position renumber
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Move a task to a new status and/or position within its column.

  Uses optimistic locking via `lock_version` to prevent lost updates when two
  clients drag the same task concurrently. On conflict, returns
  `{:error, :stale}` (not a changeset error) so the caller can reload and
  retry.

  After a successful move, renumbers the destination column to maintain
  gap-based ordering (positions spaced by 100).

  ## Options

  - `:before_id` — place before this task in the target column
  - `:after_id` — place after this task in the target column
  - If neither is given, appends to the end of the target column.
  """
  def move_task(%Task{} = task, new_status, opts \\ []) do
    workspace_id = task.workspace_id
    lock_version = task.lock_version

    target_position = compute_insert_position(workspace_id, new_status, opts)

    case task
         |> Task.move_changeset(%{
           "status" => new_status,
           "position" => target_position,
           "lock_version" => lock_version
         })
         |> Repo.update(stale_error_field: :lock_version) do
      {:ok, updated} ->
        renumber_column(workspace_id, new_status)
        # Goal progress derives from linked task statuses — recompute when
        # the status changed (moving within the same column does not affect it).
        if task.status != new_status, do: recompute_linked_goals(updated)
        # Recurring tasks clone themselves on completion.
        Dran.Tasks.Automation.handle_completion(updated)
        broadcast_task_change(updated, :moved)
        {:ok, updated}

      {:error, %Ecto.Changeset{} = changeset} ->
        # optimistic_lock sets :lock_version error on conflict
        if changeset.errors[:lock_version] do
          {:error, :stale}
        else
          {:error, changeset}
        end
    end
  end

  @doc "Max position in a column (0 if empty). Used by Task.create_changeset."
  def max_position(workspace_id, status) when is_binary(workspace_id) and is_binary(status) do
    Repo.one(
      from t in Task,
        where: t.workspace_id == ^workspace_id and t.status == ^status,
        select: coalesce(max(t.position), 0)
    )
  end

  # Compute where to insert the task in the target column.
  #
  # Gap-based ordering: positions are spaced by 100. To insert between two
  # neighbors, we take the midpoint. If the gap gets too small (< 10), the
  # renumber pass will re-space the entire column.
  defp compute_insert_position(workspace_id, status, opts) do
    before_id = Keyword.get(opts, :before_id)
    after_id = Keyword.get(opts, :after_id)

    cond do
      # Insert before a specific task → midpoint between prev and target
      before_id ->
        before_task = Repo.get(Task, before_id)
        prev_pos = prev_position(workspace_id, status, before_task.position)

        div(prev_pos + before_task.position, 2)

      # Insert after a specific task → midpoint between target and next
      after_id ->
        after_task = Repo.get(Task, after_id)
        next_pos = next_position(workspace_id, status, after_task.position)

        div(after_task.position + next_pos, 2)

      # No anchor → append at end
      true ->
        max_position(workspace_id, status) + 100
    end
  end

  defp prev_position(workspace_id, status, current_pos) do
    Repo.one(
      from t in Task,
        where:
          t.workspace_id == ^workspace_id and
            t.status == ^status and
            t.position < ^current_pos,
        select: coalesce(max(t.position), 0)
    )
  end

  defp next_position(workspace_id, status, current_pos) do
    Repo.one(
      from t in Task,
        where:
          t.workspace_id == ^workspace_id and
            t.status == ^status and
            t.position > ^current_pos,
        select: min(t.position)
    )
    |> case do
      nil -> current_pos + 100
      pos -> pos
    end
  end

  # Renumber a column so positions are spaced by 100 again.
  # Only runs if the smallest gap in the column is < 10 (avoids unnecessary
  # writes on every move).
  defp renumber_column(workspace_id, status) do
    tasks =
      from(t in Task,
        where: t.workspace_id == ^workspace_id and t.status == ^status,
        order_by: [asc: t.position],
        select: [:id, :position]
      )
      |> Repo.all()

    positions = Enum.map(tasks, & &1.position)
    min_gap = min_gap(positions)

    if min_gap == nil or min_gap < 10 do
      {updates, _acc} =
        Enum.map_reduce(tasks, 100, fn task, pos ->
          {{task.id, pos}, pos + 100}
        end)

      # Update all positions in a single transaction
      Repo.transaction(fn ->
        Enum.each(updates, fn {id, pos} ->
          Repo.update_all(from(t in Task, where: t.id == ^id), set: [position: pos])
        end)
      end)
    end
  end

  defp min_gap([]), do: nil
  defp min_gap([_single]), do: nil

  defp min_gap(positions) do
    positions
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [a, b] -> b - a end)
    |> Enum.min()
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Helpers
  # ──────────────────────────────────────────────────────────────────────────

  defp ensure_slug(attrs) do
    slug = Map.get(attrs, "slug") || Map.get(attrs, :slug)
    title = Map.get(attrs, "title") || Map.get(attrs, :title)
    workspace_id = Map.get(attrs, "workspace_id") || Map.get(attrs, :workspace_id)

    # Without a workspace we cannot guarantee slug uniqueness — let
    # validate_required(:workspace_id) produce the error instead.
    cond do
      is_binary(slug) and String.trim(slug) != "" ->
        attrs

      is_binary(workspace_id) ->
        generated = Slug.generate(title, workspace_id, "task")
        generated = ensure_unique_task_slug(generated, workspace_id, 0)
        key = if Map.has_key?(attrs, :title), do: :slug, else: "slug"
        Map.put(attrs, key, generated)

      true ->
        attrs
    end
  end

  # Slug.generate already calls Knowledge.get_page_by_slug for uniqueness.
  # We need an additional check against the tasks table.
  defp ensure_unique_task_slug(base, workspace_id, attempt) do
    candidate = if attempt == 0, do: base, else: "#{base}-#{random_hex()}"

    if get_task_by_slug(candidate, workspace_id) do
      ensure_unique_task_slug(base, workspace_id, attempt + 1)
    else
      candidate
    end
  end

  defp random_hex do
    :crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)
  end

  defp default_owner_fields(attrs) do
    attrs
    |> Map.put_new("created_by", "system")
    |> put_creator_actor()
  end

  # F6: the acting actor is attributed BY ID. Callers may pass
  # "creator_actor_id" explicitly (server-resolved); otherwise it is derived
  # from "created_by" — which for API keys is the key's actor name and for
  # users the email (user actors are named by email) — via the actors
  # registry. One lookup per create; unknown identities simply carry no id.
  defp put_creator_actor(%{"creator_actor_id" => id} = attrs) when is_binary(id), do: attrs

  defp put_creator_actor(%{"created_by" => name} = attrs)
       when is_binary(name) and name != "system" do
    case Dran.Actors.get_actor_by_name(name) do
      %Dran.Actors.Actor{id: id} -> Map.put(attrs, "creator_actor_id", id)
      _ -> attrs
    end
  end

  defp put_creator_actor(attrs), do: attrs
end
