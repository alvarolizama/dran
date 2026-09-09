defmodule Dran.Goals do
  @moduledoc """
  The Goals context — CRUD for goals (`Dran.Goals.Goal`).

  Owns listing and the full changeset-backed CRUD over the goals table.
  Leaf context: depends only on Repo + its schema.
  """

  import Ecto.Query, warn: false

  alias Dran.Repo
  alias Dran.Goals.Goal
  alias Dran.Slug

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

  @doc "Create a new goal. The slug is auto-managed (derived from title)."
  def create_goal(attrs) do
    attrs
    |> Slug.inject_create(
      fallback: "goal",
      taken?: &slug_taken?(attrs, &1)
    )
    |> then(&(%Goal{} |> Goal.changeset(&1) |> Repo.insert()))
  end

  @doc """
  Update an existing goal. The slug is auto-managed: when the title changes
  and no explicit slug was provided, the slug is regenerated from the new
  title (suffixed with a random hex if it collides). An explicit slug in
  attrs always wins (API/MCP callers, seeds).
  """
  def update_goal(%Goal{} = goal, attrs) do
    attrs
    |> Slug.inject_update(goal,
      fallback: "goal",
      lookup: &get_goal_by_slug(&1, goal.workspace_id)
    )
    |> then(&(goal |> Goal.changeset(&1) |> Repo.update()))
  end

  defp slug_taken?(attrs, candidate) do
    case Slug.fetch_attr(attrs, "workspace_id") do
      workspace_id when is_binary(workspace_id) ->
        get_goal_by_slug(candidate, workspace_id) != nil

      _ ->
        false
    end
  end

  @doc "Delete a goal"
  def delete_goal(%Goal{} = goal), do: Repo.delete(goal)

  # ──────────────────────────────────────────────────────────────────────────
  # Linked notes (page ─part_of→ goal relations)
  # ──────────────────────────────────────────────────────────────────────────

  import Ecto.Query, only: [from: 2, where: 3]

  alias Dran.Knowledge
  alias Dran.Relation

  @doc """
  Pages linked to the goal via `part_of` relations (page → goal), with the
  relation id attached so the UI can unlink without re-querying. Optional
  `kinds` filter restricts to note kinds (e.g. `~w(plan project)`).
  """
  def linked_notes(%Goal{} = goal, opts \\ []) do
    kinds = Keyword.get(opts, :kinds)

    query =
      from r in Relation,
        where:
          r.target_id == ^goal.id and
            r.target_type == "goal" and
            r.relation_type == "part_of",
        join: p in Dran.Knowledge.Page,
        on: p.id == r.source_id and p.page_type == "note" and p.archived == false,
        order_by: [asc: p.title],
        select: %{page: p, relation_id: r.id}

    query =
      if kinds do
        where(query, [_, p], p.meta["kind"] in ^kinds)
      else
        query
      end

    Repo.all(query)
  end

  @doc "Link a page to the goal with a `part_of` relation (page → goal)."
  def link_note(%Goal{} = goal, %Dran.Knowledge.Page{} = page) do
    Knowledge.create_relation(%{
      source_id: page.id,
      source_type: "page",
      target_id: goal.id,
      target_type: "goal",
      relation_type: "part_of"
    })
  end

  @doc "Unlink a page from the goal by removing the `part_of` relation."
  def unlink_note(%Goal{} = goal, %Dran.Knowledge.Page{} = page) do
    from(r in Relation,
      where:
        r.source_id == ^page.id and r.source_type == "page" and
          r.target_id == ^goal.id and r.target_type == "goal" and
          r.relation_type == "part_of"
    )
    |> Repo.delete_all()
    |> case do
      {count, _} when count > 0 -> :ok
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Notes of the workspace available to link (kind plan/project, not archived,
  not already linked). Backs the goal sidebar picker.
  """
  def linkable_notes(%Goal{} = goal, kinds \\ ~w(plan project)) do
    linked_ids =
      from(r in Relation,
        where: r.target_id == ^goal.id and r.target_type == "goal",
        select: r.source_id
      )
      |> Repo.all()

    from(p in Dran.Knowledge.Page,
      where:
        p.workspace_id == ^goal.workspace_id and
          p.page_type == "note" and
          p.archived == false and
          p.meta["kind"] in ^kinds and
          p.id not in ^linked_ids,
      order_by: [asc: p.title],
      limit: 100,
      select: %{id: p.id, title: p.title, slug: p.slug, kind: p.meta["kind"]}
    )
    |> Repo.all()
  end

  @doc "Detach a workflow from the goal (`goal_id` → nil)."
  def detach_workflow(%Goal{} = goal, workflow) do
    Dran.Workflows.update_workflow(workflow, %{
      "goal_id" => nil,
      "workspace_id" => goal.workspace_id
    })
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Checklist (lightweight sub-items on the goal itself)
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Append a checklist item (`%{"text" => text, "done" => false}`).
  Empty/whitespace text is rejected with `{:error, :empty_text}`.
  """
  def add_checklist_item(%Goal{} = goal, text) when is_binary(text) do
    text = String.trim(text)

    if text == "" do
      {:error, :empty_text}
    else
      item = %{"text" => text, "done" => false}
      update_goal(goal, %{"checklist" => goal.checklist ++ [item]})
    end
  end

  @doc "Flip the `done` flag of the checklist item at `index`."
  def toggle_checklist_item(%Goal{} = goal, index) when is_integer(index) do
    checklist =
      goal.checklist
      |> Enum.with_index()
      |> Enum.map(fn {item, i} ->
        if i == index, do: %{item | "done" => !item["done"]}, else: item
      end)

    update_goal(goal, %{"checklist" => checklist})
  end

  @doc "Remove the checklist item at `index`."
  def remove_checklist_item(%Goal{} = goal, index) when is_integer(index) do
    checklist =
      goal.checklist
      |> Enum.with_index()
      |> Enum.reject(fn {_item, i} -> i == index end)
      |> Enum.map(&elem(&1, 0))

    update_goal(goal, %{"checklist" => checklist})
  end

  @doc "`{done, total}` counts for the goal's checklist — backs the badge."
  def checklist_progress(%Goal{checklist: checklist}) do
    done = Enum.count(checklist, & &1["done"])
    {done, length(checklist)}
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Tree helpers (parent_goal_id hierarchy)
  # ──────────────────────────────────────────────────────────────────────────

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
end
