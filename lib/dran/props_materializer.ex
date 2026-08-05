defmodule Dran.PropsMaterializer do
  @moduledoc """
  Turns `meta.props` custom properties into first-class graph edges.

  The props map on a page is free-form user metadata (e.g.
  `%{"role" => "sales", "tier" => "vip"}`). By itself it is data the graph
  cannot see — PageRank, community detection and GraphRAG only consume
  edges. This module materializes known props into typed relations so the
  graph feels them.

  For each materializable prop on a page:

  1. **Get-or-create** a target page in the same context (deduped by slug).
     The target's `page_type` depends on the prop (see `@prop_map`).
  2. **Create a typed relation** from the source page to the target page.

  Like `Dran.EntityLinker`, this runs inside the augmenter with a `rescue`
  so a materialization crash never breaks the pipeline. Zero inference
  cost — pure pattern matching on a map.

  ## Prop map

  Hardcoded for now; extend by adding entries to `@prop_map`.

  | Prop key   | Relation type | Target page_type | Example                        |
  |------------|---------------|------------------|--------------------------------|
  | role       | works_in      | entity           | `role: "sales"` → works_in → entity "sales" |
  | tier       | has_tier      | concept          | `tier: "vip"` → has_tier → concept "vip"   |
  | location   | based_in      | entity           | `location: "cdmx"` → based_in → entity "cdmx" |
  | language   | written_in    | entity           | `language: "elixir"` → written_in → entity "elixir" |
  | framework  | built_with    | entity           | `framework: "phoenix"` → built_with → entity "phoenix" |

  ## Safety rails

  * Props NOT in `@prop_map` are silently ignored (they stay in `meta.props`
    but generate no edge).
  * Skips self-links (a page whose slug matches the target slug).
  * Skips targets whose slug collides with an existing page of a different
    `page_type` than the mapped one (never hijack a note's slug).
  * Caps materializations per page at `@max_props_per_page`.
  * Relations use `Brain.create_relation/1` (on_conflict: :nothing), so
    re-running the augmenter is idempotent.
  """

  require Logger

  alias Dran.Brain
  alias Dran.Brain.Page
  alias Dran.Slug

  @max_props_per_page 10

  # prop_key => {relation_type, target_page_type}
  @prop_map %{
    "role" => {"works_in", "entity"},
    "tier" => {"has_tier", "concept"},
    "location" => {"based_in", "entity"},
    "language" => {"written_in", "entity"},
    "framework" => {"built_with", "entity"}
  }

  @doc "The prop keys this module knows how to materialize."
  def materializable_keys, do: Map.keys(@prop_map)

  @doc """
  Materialize a page's `meta.props` into typed relations.

  Returns `{:ok, created_count}` where `created_count` is the number of new
  relations created. Pages without props or with only unmapped props return
  `{:ok, 0}`.
  """
  @spec materialize(Page.t()) :: {:ok, non_neg_integer()}
  def materialize(%Page{context_id: nil}), do: {:ok, 0}

  def materialize(%Page{} = page) do
    props = extract_props(page)

    if map_size(props) == 0 do
      {:ok, 0}
    else
      created =
        props
        |> Enum.take(@max_props_per_page)
        |> Enum.reduce(0, fn {prop_key, prop_value}, acc ->
          case materialize_one(page, prop_key, prop_value) do
            {:ok, :linked} -> acc + 1
            _ -> acc
          end
        end)

      {:ok, created}
    end
  end

  # ── Internals ──

  defp extract_props(%Page{meta: meta}) when is_map(meta) do
    case Map.get(meta, "props") || Map.get(meta, :props) do
      props when is_map(props) -> props
      _ -> %{}
    end
  end

  defp extract_props(_), do: %{}

  defp materialize_one(page, prop_key, prop_value) do
    with {:ok, {relation_type, target_type}} <- fetch_mapping(prop_key),
         {:ok, target_slug} <- normalize_value(prop_value),
         :ok <- skip_self_link(page, target_slug),
         {:ok, target_page} <- get_or_create_target(page, target_slug, target_type),
         :ok <- create_typed_edge(page, target_page, relation_type) do
      {:ok, :linked}
    else
      {:skip, reason} ->
        Logger.debug("PropsMaterializer skip #{page.slug}.#{prop_key}: #{reason}")
        {:error, reason}

      {:error, reason} ->
        Logger.warning("PropsMaterializer failed #{page.slug}.#{prop_key}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp fetch_mapping(prop_key) do
    case Map.get(@prop_map, to_string(prop_key)) do
      nil -> {:skip, "prop not in materializable map"}
      mapping -> {:ok, mapping}
    end
  end

  defp normalize_value(value) when is_binary(value) do
    slug =
      value
      |> String.trim()
      |> Slug.slugify()

    if slug in ["", "untitled"] do
      {:skip, "empty or invalid prop value"}
    else
      {:ok, slug}
    end
  end

  defp normalize_value(_), do: {:skip, "prop value is not a string"}

  defp skip_self_link(%Page{slug: slug}, slug), do: {:skip, "self-link"}
  defp skip_self_link(_, _), do: :ok

  defp get_or_create_target(page, target_slug, target_type) do
    case Brain.get_page_by_slug(target_slug, page.context_id) do
      nil ->
        create_target_page(page, target_slug, target_type)

      %Page{page_type: ^target_type} = existing ->
        {:ok, existing}

      %Page{page_type: other} ->
        {:skip, "slug taken by #{other} page"}
    end
  end

  defp create_target_page(page, target_slug, target_type) do
    attrs = %{
      context_id: page.context_id,
      title: titleize(target_slug),
      slug: target_slug,
      page_type: target_type,
      body: "",
      owner: page.owner || "system",
      created_by: "props_materializer",
      meta: %{"auto" => true, "created_from" => "props_materializer"}
    }

    case Brain.create_page(attrs) do
      {:ok, target_page} ->
        {:ok, target_page}

      {:error, %Ecto.Changeset{} = changeset} ->
        # Race: another augmenter created it concurrently — fetch and reuse.
        case Brain.get_page_by_slug(target_slug, page.context_id) do
          %Page{page_type: t} = existing when t == target_type ->
            {:ok, existing}

          _ ->
            {:error, changeset}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_typed_edge(page, target_page, relation_type) do
    case Brain.create_relation(%{
           source_id: page.id,
           target_id: target_page.id,
           relation_type: relation_type,
           meta: %{"auto" => true, "created_from" => "props_materializer"}
         }) do
      {:ok, _} -> :ok
      # on_conflict: :nothing returns the struct unchanged on dupes — treat as ok
      {:error, _} -> :ok
    end
  end

  defp titleize(slug) do
    slug
    |> String.split("-")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end
end
