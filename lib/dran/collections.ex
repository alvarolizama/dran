defmodule Dran.Collections do
  @moduledoc """
  The Collections context — CRUD for collections (`Dran.Collections.Collection`).

  Curated groupings of pages within a workspace. Leaf context: depends
  only on Repo + its schema.
  """

  import Ecto.Query, warn: false

  alias Dran.Repo
  alias Dran.Collections.Collection

  # ──────────────────────────────────────────────────────────────────────────
  # Collection CRUD
  # ──────────────────────────────────────────────────────────────────────────

  @doc "Get a collection by slug within a workspace"
  def get_collection_by_slug(slug, workspace_id)
      when is_binary(slug) and is_binary(workspace_id) do
    Repo.one(from c in Collection, where: c.slug == ^slug and c.workspace_id == ^workspace_id)
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

  @doc "Delete a collection"
  def delete_collection(%Collection{} = collection), do: Repo.delete(collection)

  @doc "List collections in a workspace"
  def list_collections(workspace_id) when is_binary(workspace_id) do
    Repo.all(
      from c in Collection, where: c.workspace_id == ^workspace_id, order_by: [asc: c.name]
    )
  end
end
