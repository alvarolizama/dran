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

  @doc """
  Get a collection by slug within a workspace.

  Unscoped on purpose: this clause is for internal/system callers (slug
  bookkeeping, tests). Read surfaces use the `scope:` clause below.
  """
  def get_collection_by_slug(slug, workspace_id)
      when is_binary(slug) and is_binary(workspace_id) do
    Repo.one(from c in Collection, where: c.slug == ^slug and c.workspace_id == ^workspace_id)
  end

  @doc """
  Scope-aware fetch (W2): a row outside the reader's scope reads as a missing
  row — no existence leak. Same shape as `Knowledge.get_page_by_slug/3`.
  """
  def get_collection_by_slug(slug, workspace_id, scope: scope)
      when is_binary(slug) and is_binary(workspace_id) do
    Collection
    |> where(slug: ^slug, workspace_id: ^workspace_id)
    |> Dran.ContentVisibility.filter(scope, :collection)
    |> Repo.one()
  end

  @doc """
  Create a new collection. The slug is auto-managed (derived from name).

  `"owner_user_id"` carries the caller's SERVER-SIDE identity (the session
  user); it is never taken from a client body. The read policy consults it,
  and a NULL owner means workspace-wide content (system producers).
  """
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

  @doc """
  List collections in a workspace.

  Opts: `:scope` — the reader's `Dran.ContentVisibility` scope. It defaults to
  `:all` (internal/system callers), the same default `Knowledge.list_pages/1`
  uses; every surface that renders for a reader passes the resolved scope.
  """
  def list_collections(workspace_id, opts \\ []) when is_binary(workspace_id) do
    from(c in Collection,
      where: c.workspace_id == ^workspace_id,
      order_by: [asc: c.name]
    )
    |> Dran.ContentVisibility.filter(Keyword.get(opts, :scope, :all), :collection)
    |> Repo.all()
  end

  @doc """
  Count collections of a workspace (sidebar badge) without loading rows.

  Deliberately UNSCOPED, like the page badges (`Knowledge.stats/1` counts
  every page): the badge counts the workspace, not the reader's view. W2 left
  it as it found it and recorded the question instead of changing it silently.
  """
  def count_collections(workspace_id) when is_binary(workspace_id) do
    Repo.one(from c in Collection, where: c.workspace_id == ^workspace_id, select: count(c.id))
  end
end
