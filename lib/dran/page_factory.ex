defmodule Dran.PageFactory do
  @moduledoc """
  Shared get-or-create for auto-generated graph node pages.

  Both `Dran.EntityLinker` and `Dran.PropsMaterializer` need the same
  primitive: given a slug and a target `page_type`, return the existing page
  or create an empty auto-generated page of that type — never hijacking an
  existing page of a different type.

  ## Safety rails

  * Skips slugs already taken by a page of a DIFFERENT `page_type`
    (`{:skip, reason}` — we never hijack a note's slug).
  * `Brain.create_page/1` race (concurrent augmenters) is handled by
    re-fetching on changeset error and reusing the winner's page.
  """

  alias Dran.Brain
  alias Dran.Page

  @doc """
  Get or create a page of `page_type` with slug `slug` in `source_page`'s
  context.

  Returns `{:ok, page}`, `{:skip, reason}`, or `{:error, reason}`.

  ## Options

  * `:created_by` — value for the `created_by` field and the
    `meta.created_from` marker (default: `"page_factory"`).
  """
  @spec get_or_create(Page.t(), binary(), binary(), keyword()) ::
          {:ok, Page.t()} | {:skip, binary()} | {:error, term()}
  def get_or_create(%Page{} = source_page, slug, page_type, opts \\ []) do
    created_by = Keyword.get(opts, :created_by, "page_factory")

    case Brain.get_page_by_slug(slug, source_page.workspace_id) do
      nil ->
        create_page(source_page, slug, page_type, created_by)

      %Page{page_type: ^page_type} = existing ->
        {:ok, existing}

      %Page{page_type: other} ->
        {:skip, "slug taken by #{other} page"}
    end
  end

  @doc """
  Create an auto-generated relation from `source_page` to `target_page`.

  `Brain.create_relation/1` uses `on_conflict: :nothing`, so duplicates are
  silently treated as ok — callers can re-run freely.
  """
  @spec create_edge(Page.t(), Page.t(), binary(), binary()) :: :ok
  def create_edge(%Page{} = source_page, %Page{} = target_page, relation_type, created_by) do
    case Brain.create_relation(%{
           source_id: source_page.id,
           target_id: target_page.id,
           relation_type: relation_type,
           meta: %{"auto" => true, "created_from" => created_by}
         }) do
      {:ok, _} -> :ok
      # on_conflict: :nothing returns the struct unchanged on dupes — treat as ok
      {:error, _} -> :ok
    end
  end

  defp create_page(source_page, slug, page_type, created_by) do
    attrs = %{
      workspace_id: source_page.workspace_id,
      title: Dran.Slug.titleize(slug),
      slug: slug,
      page_type: page_type,
      body: "",
      owner: source_page.owner || "system",
      created_by: created_by,
      meta: %{"auto" => true, "created_from" => created_by}
    }

    case Brain.create_page(attrs) do
      {:ok, page} ->
        {:ok, page}

      {:error, %Ecto.Changeset{} = changeset} ->
        # Race: another augmenter created it concurrently — fetch and reuse.
        case Brain.get_page_by_slug(slug, source_page.workspace_id) do
          %Page{page_type: ^page_type} = existing ->
            {:ok, existing}

          _ ->
            {:error, changeset}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
