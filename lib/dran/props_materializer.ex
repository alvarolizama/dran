defmodule Dran.PropsMaterializer do
  @moduledoc """
  Turns `meta.props` custom properties into first-class graph edges.

  The props map on a page is free-form user metadata (e.g.
  `%{"role" => "sales", "tier" => "vip"}`). By itself it is data the graph
  cannot see — PageRank, cluster detection and GraphRAG only consume
  edges. This module materializes known props into typed relations so the
  graph feels them.

  For each materializable prop on a page:

  1. **Resolve the target.** A pointer that casts as a uuid is resolved BY
     ID (W4a, F32) — renaming the target's slug never breaks the edge and no
     page is created with a uuid slug. A non-id value keeps the legacy
     get-or-create path, deduped by slug in the same context. The target's
     `page_type` depends on the prop (see `@prop_map`).
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
  * Skips self-links (a prop whose target id is the page itself).
  * Skips id pointers that do not resolve, or that resolve to a page of a
    different `page_type` than the mapped one.
  * Skips (legacy) slug targets that collide with an existing page of a
    different `page_type` than the mapped one (never hijack a note's slug).
  * Caps materializations per page at `@max_props_per_page`.
  * Relations use `Knowledge.create_relation/1` (on_conflict: :nothing), so
    re-running the augmenter is idempotent.
  """

  require Logger

  alias Dran.Knowledge.Page
  alias Dran.PageFactory
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
  def materialize(%Page{workspace_id: nil}), do: {:ok, 0}

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
         {:ok, target_page} <- resolve_target(page, prop_value, target_type),
         :ok <- skip_self_link(page, target_page),
         :ok <- PageFactory.create_edge(page, target_page, relation_type, "props_materializer") do
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

  # A pointer is an ID when the value casts as a uuid (W4a, F32): the target
  # is fetched BY ID, so renaming its slug never breaks the edge and no page
  # is ever created with a uuid as its slug. Non-id values keep the legacy
  # slug path (get-or-create the target of `target_type`).
  defp resolve_target(page, value, target_type) do
    case normalize_id(value) do
      {:ok, id} ->
        case Dran.Knowledge.get_page(id) do
          %Page{page_type: ^target_type} = target -> {:ok, target}
          %Page{page_type: other} -> {:skip, "id points to #{other} page"}
          nil -> {:skip, "id does not resolve"}
        end

      :error ->
        with {:ok, slug} <- normalize_value(value) do
          PageFactory.get_or_create(page, slug, target_type, created_by: "props_materializer")
        end
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

  # Cast a prop value as a uuid — the id pointer form (W4a, F32). Forged /
  # non-uuid strings are NOT ids; they take the slug path. The canonical uuid
  # string is 36 bytes: `Ecto.UUID.cast/1` also accepts a raw 16-byte binary,
  # so a 16-char prop value would be silently read as a uuid.
  defp normalize_id(value) when is_binary(value) do
    trimmed = String.trim(value)

    if byte_size(trimmed) == 36 do
      Ecto.UUID.cast(trimmed)
    else
      :error
    end
  end

  defp normalize_id(_), do: :error

  defp skip_self_link(%Page{id: id}, %Page{id: id}), do: {:skip, "self-link"}
  defp skip_self_link(_, _), do: :ok
end
