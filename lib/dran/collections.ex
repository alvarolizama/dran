defmodule Dran.Collections do
  @moduledoc """
  The Collections context — CRUD for collections (`Dran.Collection`).

  Curated groupings of pages within a workspace. Leaf context: depends
  only on Repo + its schema.
  """

  import Ecto.Query, warn: false

  alias Dran.Repo
  alias Dran.Collection

  # ──────────────────────────────────────────────────────────────────────────
  # Collection CRUD
  # ──────────────────────────────────────────────────────────────────────────

  @doc "Get a collection by slug within a workspace"
  def get_collection_by_slug(slug, workspace_id)
      when is_binary(slug) and is_binary(workspace_id) do
    Repo.one(from c in Collection, where: c.slug == ^slug and c.workspace_id == ^workspace_id)
  end

  @doc "Get a collection by id, returns nil if not found"
  def get_collection(id), do: Repo.get(Collection, id)

  @doc "Build a changeset for a collection (for LiveView forms)"
  def change_collection(%Collection{} = collection, attrs \\ %{}) do
    Collection.changeset(collection, attrs)
  end

  @doc "Create a new collection"
  def create_collection(attrs) do
    %Collection{}
    |> Collection.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Update an existing collection"
  def update_collection(%Collection{} = collection, attrs) do
    collection
    |> Collection.changeset(attrs)
    |> Repo.update()
  end

  @doc "Delete a collection"
  def delete_collection(%Collection{} = collection), do: Repo.delete(collection)

  @doc "List collections in a workspace"
  def list_collections(workspace_id) when is_binary(workspace_id) do
    Repo.all(
      from c in Collection, where: c.workspace_id == ^workspace_id, order_by: [asc: c.name]
    )
  end
end
