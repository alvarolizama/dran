defmodule Dran.Goals do
  @moduledoc """
  The Goals context — CRUD for goals (`Dran.Goal`).

  Owns listing and the full changeset-backed CRUD over the goals table.
  Leaf context: depends only on Repo + its schema.
  """

  import Ecto.Query, warn: false

  alias Dran.Repo
  alias Dran.Goal

  @doc "List goals from the goals table"
  def list_goals(workspace_id) when is_binary(workspace_id) do
    list_goals(workspace_id: workspace_id)
  end

  def list_goals(opts) when is_list(opts) do
    workspace_id = Keyword.get(opts, :workspace_id)
    limit = Keyword.get(opts, :limit, 100)
    archived = Keyword.get(opts, :archived, false)

    query =
      from(g in Goal,
        where: g.archived == ^archived,
        order_by: [asc: g.title],
        limit: ^limit
      )

    query =
      if workspace_id do
        where(query, [g], g.workspace_id == ^workspace_id)
      else
        query
      end

    Repo.all(query)
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Goal CRUD
  # ──────────────────────────────────────────────────────────────────────────

  @doc "Get a goal by slug within a workspace"
  def get_goal_by_slug(slug, workspace_id) when is_binary(slug) and is_binary(workspace_id) do
    Repo.one(from g in Goal, where: g.slug == ^slug and g.workspace_id == ^workspace_id)
  end

  @doc "Get a goal by id, returns nil if not found"
  def get_goal(id), do: Repo.get(Goal, id)

  @doc "Build a changeset for a goal (for LiveView forms)"
  def change_goal(%Goal{} = goal, attrs \\ %{}) do
    Goal.changeset(goal, attrs)
  end

  @doc "Create a new goal"
  def create_goal(attrs) do
    %Goal{}
    |> Goal.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Update an existing goal"
  def update_goal(%Goal{} = goal, attrs) do
    goal
    |> Goal.changeset(attrs)
    |> Repo.update()
  end

  @doc "Delete a goal"
  def delete_goal(%Goal{} = goal), do: Repo.delete(goal)

  # ──────────────────────────────────────────────────────────────────────────
  # Derived progress from linked tasks (opt-in relations)
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Recompute a goal's derived progress from its linked tasks.

  Progress = (done + cancelled tasks) / total linked tasks, where a task is
  "linked" via a `part_of` relation (`source_type: "task"`,
  `target_type: "goal"`).

  Goals with NO linked tasks are left untouched — manual progress
  (`meta["progress_manual"]`) keeps working exactly as before. Derived
  progress is stored in `meta["progress_derived"]` for inspection and the
  `progress` field is updated so all existing UI keeps working.

  Returns `:ok` or `{:error, reason}`.
  """
  def recompute_progress(%Goal{} = goal) do
    counts =
      Repo.one(
        from r in Dran.Relation,
          join: t in Dran.Task,
          on: t.id == r.source_id,
          where:
            r.target_id == ^goal.id and r.target_type == "goal" and
              r.source_type == "task" and r.relation_type == "part_of" and
              t.archived == false,
          select: %{
            total: count(t.id),
            done:
              coalesce(
                sum(fragment("CASE WHEN ? IN ('done', 'cancelled') THEN 1 ELSE 0 END", t.status)),
                0
              )
          }
      )

    case counts do
      %{total: 0} ->
        :ok

      %{total: total, done: done} when total > 0 ->
        progress = done / total

        meta =
          (goal.meta || %{})
          |> Map.put("progress_derived", true)
          |> Map.put("progress_manual", false)

        goal
        |> Goal.changeset(%{progress: progress, meta: meta})
        |> Repo.update()
        |> case do
          {:ok, _} -> :ok
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  @doc """
  Depth-first preorder of the workspace's goals with depth per node
  (root → children → grandchildren …) — `[{goal, depth}]`. Backs the
  indented goal selects (`DranWeb.ResourceComponents.goal_options/1`) and
  the board filter's roll-up (via `descendant_ids/2`).

  Cycle-safe: a goal that (wrongly) descends from itself is visited once
  and its subtree is cut there.
  """
  def flattened_tree(workspace_id) do
    goals = list_goals(workspace_id)
    by_parent = Enum.group_by(goals, & &1.parent_goal_id, & &1)

    Enum.flat_map(Map.get(by_parent, nil, []), &subtree(&1, by_parent, 0, MapSet.new()))
  end

  defp subtree(goal, by_parent, depth, visited) do
    if MapSet.member?(visited, goal.id) do
      []
    else
      visited = MapSet.put(visited, goal.id)

      children =
        by_parent
        |> Map.get(goal.id, [])
        |> Enum.flat_map(&subtree(&1, by_parent, depth + 1, visited))

      [{goal, depth} | children]
    end
  end

  @doc """
  All descendant goal ids of `goal_id` within the given goal list, at any
  depth. Walks `parent_goal_id` (self-referencing) in memory — the same
  data the goal selects consume, so there is no extra query. Cycle-safe:
  a goal that (wrongly) descends from itself terminates.
  """
  def descendant_ids(goal_id, goals) when is_list(goals) do
    by_parent = Enum.group_by(goals, & &1.parent_goal_id, & &1)
    do_descendants(Map.get(by_parent, goal_id, []), by_parent, MapSet.new())
  end

  defp do_descendants([], _by_parent, acc), do: MapSet.to_list(acc)

  defp do_descendants([goal | rest], by_parent, acc) do
    if MapSet.member?(acc, goal.id) do
      do_descendants(rest, by_parent, acc)
    else
      children = Map.get(by_parent, goal.id, [])
      do_descendants(rest ++ children, by_parent, MapSet.put(acc, goal.id))
    end
  end

  @doc """
  Recompute derived progress for all goals in a workspace. Used by the
  task-migration backfill and after bulk task operations.
  """
  def recompute_all_progress(workspace_id) when is_binary(workspace_id) do
    goals = Repo.all(from g in Goal, where: g.workspace_id == ^workspace_id)

    Enum.each(goals, &recompute_progress/1)
    :ok
  end
end
