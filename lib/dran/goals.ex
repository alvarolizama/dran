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
end
