defmodule Dran.SmartCollection do
  @moduledoc """
  Smart Collection helper logic.

  A smart collection is a note page whose `meta` field
  contains a `"query"` map with filter criteria. This module parses that query
  map into the keyword-list options that `Knowledge.list_pages/1` expects, and
  builds the query map from user-facing filter parameters.

  ## Query format

      %{
        "type" => "todo",
        "tag" => "urgent",
        "status" => "in_progress",
        "owner" => "alvaro",
        "due_before" => "2026-07-20",
        "due_after" => "2026-07-01"
      }

  All keys are optional; an empty query matches all pages in the context.
  The special value `"<today>"` for date fields is resolved to the current date
  at query time, making saved collections dynamic.
  """

  alias Dran.Knowledge

  @doc """
  Parse a saved query map (from `meta.query`) into a keyword list
  suitable for `Knowledge.list_pages/1`.

  ## Example

      iex> Dran.SmartCollection.query_to_opts(%{"type" => "todo", "status" => "in_progress"})
      [type: "note", kind: "todo", status: "in_progress"]
  """
  def query_to_opts(query) when is_map(query) do
    type = query["type"] || query[:type]

    # "todo"/"plan" are no longer page types — they are notes with a kind.
    {type_opt, kind_opt} =
      case type do
        t when t in ["todo", "plan"] -> {"note", t}
        t -> {t, nil}
      end

    []
    |> maybe_put(:type, type_opt)
    |> maybe_put(:kind, kind_opt)
    |> maybe_put(:tag, query["tag"] || query[:tag])
    |> maybe_put(:status, query["status"] || query[:status])
    |> maybe_put(:owner, query["owner"] || query[:owner])
    |> maybe_put(:created_by, query["created_by"] || query[:created_by])
    |> maybe_put(:due_before, resolve_date(query["due_before"] || query[:due_before]))
    |> maybe_put(:due_after, resolve_date(query["due_after"] || query[:due_after]))
  end

  def query_to_opts(nil), do: []

  @doc """
  Execute the saved query against the Brain context.

  Returns a list of pages matching the filter criteria.
  The `workspace_id` is always injected; the query's own filters are applied
  on top.

  ## Options

  - `:limit` — max results (default 200 for collections, generous)
  """
  def execute(query, workspace_id, opts \\ [])

  def execute(query, workspace_id, opts) when is_map(query) and is_binary(workspace_id) do
    limit = Keyword.get(opts, :limit, 200)

    query
    |> query_to_opts()
    |> Keyword.put(:workspace_id, workspace_id)
    |> Keyword.put(:limit, limit)
    |> Knowledge.list_pages()
  end

  def execute(nil, workspace_id, opts) when is_binary(workspace_id) do
    limit = Keyword.get(opts, :limit, 200)
    Knowledge.list_pages(workspace_id: workspace_id, limit: limit)
  end

  @doc """
  Build a query map from filter parameters (e.g. from a form or URL params).

  Strips empty/nil values so the saved query is clean.

  ## Example

      iex> Dran.SmartCollection.build_query(%{"type" => "todo", "status" => "", "tag" => "urgent"})
      %{"type" => "todo", "tag" => "urgent"}
  """
  def build_query(params) when is_map(params) do
    keys = ~w(type tag status owner created_by due_before due_after)

    keys
    |> Enum.reduce(%{}, fn key, acc ->
      value =
        params[key] ||
          params[String.to_atom(key)]

      case value do
        nil ->
          acc

        "" ->
          acc

        v when is_binary(v) ->
          trimmed = String.trim(v)
          if trimmed == "", do: acc, else: Map.put(acc, key, trimmed)

        v ->
          Map.put(acc, key, v)
      end
    end)
  end

  @doc """
  Create a smart collection page.

  Creates a page with `page_type: "note"` and `meta.query` containing
  the filter criteria (legacy module — kept for compatibility).

  ## Options

  - `:title` — display name for the collection (required)
  - `:slug` — URL slug (derived from title if omitted)
  - `:query` — the filter map (see `build_query/1`)
  - `:workspace_id` — the brain context (required)
  - `:owner` — owner field (default "system")
  - `:created_by` — created_by field (default "system")
  """
  def create(attrs) when is_map(attrs) do
    %{
      "workspace_id" => workspace_id,
      "query" => query,
      "title" => title
    } = attrs

    slug = attrs["slug"] || attrs[:slug] || slugify(title)
    meta = %{"query" => build_query(query)}

    page_attrs = %{
      "workspace_id" => workspace_id,
      "title" => title,
      "slug" => slug,
      "page_type" => "note",
      "body" => attrs["body"] || attrs[:body] || "",
      "summary" => attrs["summary"] || attrs[:summary] || query_summary(query),
      "tags" => attrs["tags"] || attrs[:tags] || [],
      "meta" => meta,
      "owner" => attrs["owner"] || attrs[:owner] || "system",
      "created_by" => attrs["created_by"] || attrs[:created_by] || "system"
    }

    Knowledge.create_page(page_attrs)
  end

  @doc """
  Get a smart collection page by slug within a context.

  Returns `nil` if the page doesn't exist or is not a note page with a
  `meta.query` filter.
  """
  def get_by_slug(slug, workspace_id) when is_binary(slug) and is_binary(workspace_id) do
    case Knowledge.get_page_by_slug(slug, workspace_id) do
      %{page_type: "note", meta: %{"query" => _}} = page -> page
      _ -> nil
    end
  end

  @doc """
  List all smart collections (note pages with a `meta.query` filter) in a context.
  """
  def list_all(workspace_id) when is_binary(workspace_id) do
    Knowledge.list_pages(workspace_id: workspace_id, type: "note", limit: 100)
    |> Enum.filter(&collection_page?/1)
  end

  defp collection_page?(%{meta: meta}) when is_map(meta), do: Map.has_key?(meta, "query")
  defp collection_page?(_), do: false

  # ── Helpers ──

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp resolve_date("<today>"), do: Date.utc_today() |> Date.to_iso8601()
  defp resolve_date(date) when is_binary(date), do: date
  defp resolve_date(%Date{} = date), do: Date.to_iso8601(date)
  defp resolve_date(nil), do: nil

  defp query_summary(query) when is_map(query) and map_size(query) > 0 do
    query
    |> Enum.map(fn {k, v} -> "#{k}: #{v}" end)
    |> Enum.join(", ")
  end

  defp query_summary(_), do: "All pages"

  defp slugify(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.replace(~r/^-+|-+$/, "")
    |> case do
      "" -> "collection"
      slug -> slug
    end
  end
end
