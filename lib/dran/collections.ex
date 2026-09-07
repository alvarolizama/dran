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

  @doc "Create a new collection. The slug is auto-managed (derived from name)."
  def create_collection(attrs) do
    attrs
    |> Dran.Slug.inject_create(
      field: "name",
      fallback: "collection",
      taken?: fn candidate ->
        case Dran.Slug.fetch_attr(attrs, "workspace_id") do
          workspace_id when is_binary(workspace_id) ->
            get_collection_by_slug(candidate, workspace_id) != nil

          _ ->
            false
        end
      end
    )
    |> then(&(%Collection{} |> Collection.changeset(&1) |> Repo.insert()))
  end

  @doc """
  Update an existing collection. The slug is auto-managed: regenerated from
  the name when it changes (unless attrs carry an explicit slug).
  """
  def update_collection(%Collection{} = collection, attrs) do
    attrs
    |> Dran.Slug.inject_update(collection,
      field: "name",
      fallback: "collection",
      lookup: &get_collection_by_slug(&1, collection.workspace_id)
    )
    |> then(&(collection |> Collection.changeset(&1) |> Repo.update()))
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
