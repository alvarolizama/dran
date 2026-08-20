defmodule Dran.Exporter do
  @moduledoc """
  Context exporter — serializes a context, its pages (with body),
  and the relations between its pages into a JSON-serializable map.
  """

  import Ecto.Query, warn: false

  alias Dran.Repo
  alias Dran.Brain
  alias Dran.{Workspace, Page, Relation, PageVersion}

  @doc """
  Export a context by slug.

  Returns `{:ok, map}` on success or `{:error, :not_found}` when the
  context slug doesn't exist.

  The returned map is directly JSON-serializable and contains:

    * `exported_at` — UTC timestamp string
    * `workspace`     — `%{name, slug, description}`
    * `pages`       — list of page maps (slug, title, page_type, body,
                      summary, tags, meta, timestamps)
    * `relations`   — list of `%{source_slug, target_slug, relation_type}`
  """
  def export_context(workspace_slug) when is_binary(workspace_slug) do
    case Brain.get_workspace_by_slug(workspace_slug) do
      nil ->
        {:error, :not_found}

      %Dran.Workspace{} = context ->
        pages = load_pages(context.id)

        page_ids = Enum.map(pages, & &1.id)
        slug_by_id = Map.new(pages, &{&1.id, &1.slug})

        relations = load_relations(page_ids, slug_by_id)

        data = %{
          exported_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          workspace: %{
            name: context.name,
            slug: context.slug,
            description: nil
          },
          pages: Enum.map(pages, &serialize_page/1),
          relations: relations
        }

        {:ok, data}
    end
  end

  @doc """
  Full export of a context by its id.

  Returns `{:ok, map}` on success or `{:error, :not_found}` when the
  context doesn't exist.

  The returned map contains:

    * `exported_at` — UTC timestamp string
    * `workspace`     — `%{id, name, slug, inserted_at}`
    * `pages`       — list of page maps (slug, title, page_type, body,
                      summary, tags, meta, version, timestamps)
    * `relations`   — list of `%{source_slug, target_slug, relation_type, weight}`
    * `versions`    — list of all page_version snapshots for those pages
                      `%{page_slug, version, body, body_hash, changed_by, inserted_at}`
  """
  def full_export(workspace_id) when is_binary(workspace_id) do
    case Repo.get(Workspace, workspace_id) do
      nil ->
        {:error, :not_found}

      %Workspace{} = context ->
        pages = load_pages(context.id)
        page_ids = Enum.map(pages, & &1.id)
        slug_by_id = Map.new(pages, &{&1.id, &1.slug})

        relations = load_relations(page_ids, slug_by_id)
        versions = load_versions(page_ids, slug_by_id)

        data = %{
          exported_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          workspace: %{
            id: context.id,
            name: context.name,
            slug: context.slug,
            inserted_at: context.inserted_at
          },
          pages: Enum.map(pages, &serialize_page/1),
          relations: relations,
          versions: versions
        }

        {:ok, data}
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp load_pages(workspace_id) do
    Repo.all(
      from p in Page,
        where: p.workspace_id == ^workspace_id,
        order_by: [asc: p.slug]
    )
  end

  defp load_relations(page_ids, slug_by_id) do
    if Enum.empty?(page_ids) do
      []
    else
      Repo.all(
        from r in Relation,
          where: r.source_id in ^page_ids and r.target_id in ^page_ids,
          order_by: [asc: r.relation_type, asc: r.source_id, asc: r.target_id],
          preload: [:source, :target]
      )
      |> Enum.map(fn rel ->
        %{
          source_slug: slug_from_preload(rel.source, slug_by_id),
          target_slug: slug_from_preload(rel.target, slug_by_id),
          relation_type: rel.relation_type,
          weight: rel.weight
        }
      end)
    end
  end

  defp load_versions(page_ids, slug_by_id) do
    if Enum.empty?(page_ids) do
      []
    else
      Repo.all(
        from pv in PageVersion,
          where: pv.page_id in ^page_ids,
          order_by: [asc: pv.page_id, asc: pv.version]
      )
      |> Enum.map(fn pv ->
        %{
          page_slug: Map.get(slug_by_id, pv.page_id),
          version: pv.version,
          body: pv.body,
          body_hash: pv.body_hash,
          changed_by: pv.changed_by,
          inserted_at: pv.inserted_at
        }
      end)
    end
  end

  defp slug_from_preload(%Page{slug: slug}, _slug_by_id), do: slug
  defp slug_from_preload(nil, slug_by_id), do: slug_by_id

  defp serialize_page(%Page{} = page) do
    %{
      slug: page.slug,
      title: page.title,
      page_type: page.page_type,
      body: page.body,
      summary: page.summary,
      tags: page.tags,
      meta: page.meta,
      version: page.version,
      inserted_at: page.inserted_at,
      updated_at: page.updated_at
    }
  end
end
