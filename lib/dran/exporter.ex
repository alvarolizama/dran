defmodule Dran.Exporter do
  @moduledoc """
  Context exporter — serializes a context, its pages (with body),
  and outbound relations into a JSON-serializable map.
  """

  import Ecto.Query, warn: false

  alias Dran.Repo
  alias Dran.Brain
  alias Dran.Brain.{Page, Relation}

  @doc """
  Export a context by slug.

  Returns `{:ok, map}` on success or `{:error, :not_found}` when the
  context slug doesn't exist.

  The returned map is directly JSON-serializable and contains:

    * `exported_at` — UTC timestamp string
    * `context`     — `%{name, slug, description}`
    * `pages`       — list of page maps (slug, title, page_type, body,
                      summary, tags, meta, timestamps)
    * `relations`   — list of `%{source_slug, target_slug, relation_type}`
  """
  def export_context(context_slug) when is_binary(context_slug) do
    case Brain.get_context_by_slug(context_slug) do
      nil ->
        {:error, :not_found}

      %Dran.Brain.Context{} = context ->
        pages = load_pages(context.id)

        page_ids = Enum.map(pages, & &1.id)
        slug_by_id = Map.new(pages, &{&1.id, &1.slug})

        relations = load_relations(page_ids, slug_by_id)

        data = %{
          exported_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          context: %{
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

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp load_pages(context_id) do
    Repo.all(
      from p in Page,
        where: p.context_id == ^context_id,
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
          relation_type: rel.relation_type
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
      inserted_at: page.inserted_at,
      updated_at: page.updated_at
    }
  end

end
