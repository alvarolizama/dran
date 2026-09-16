defmodule Dran.GraphCache do
  @moduledoc """
  ETS-backed cache for graph payloads and page lookups.

  Two cache tables, both with `read_concurrency: true`:

  | Table              | Key                          | Value                | Invalidated by           |
  |--------------------|------------------------------|----------------------|--------------------------|
  | `:dran_graph_cache`| `workspace_id`                 | global graph JSON    | `invalidate_context/1`  |
  | `:dran_page_cache` | `{slug, workspace_id}`         | `%Page{}` or `:not_found` | `invalidate_page_slug/2` |

  The GenServer owns the tables (creates them in `init/1`) and handles
  all writes (build + insert). Reads go directly to ETS — no GenServer
  call, no serialization, no bottleneck.

  Invalidation is triggered by `Knowledge.broadcast_page_change/3`:
    - `invalidate_context/1` wipes the global graph for the context
    - `invalidate_page/2` wipes the global graph for that page
    - `invalidate_page_slug/2` wipes the page-cache entry for that slug
  """

  use GenServer

  alias Dran.Knowledge
  alias DranWeb.GraphHelpers

  # Types hidden from the global graph — the canonical list lives in the
  # Dran.PageTypes capability registry. Currently all 5 remaining types
  # have graph: true, so this list is empty but kept for future use.
  @hidden_by_default Dran.PageTypes.hidden_from_graph()
  @max_graph_nodes 400

  # Tables
  @graph_table :dran_graph_cache
  @page_table :dran_page_cache

  # ── Public API ─────────────────────────────────────────────────────────

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc """
  Get the cached global graph JSON for a context, building if missing.
  Returns `%{json: binary(), cached: boolean()}`.
  Reads from ETS directly; on miss, calls the GenServer to build + cache.

  The cache key includes the reader's scope: the graph is now visibility-
  filtered, so one payload per workspace would leak the first reader's view
  to everyone else.
  """
  def get(workspace_id, scope \\ :all) do
    key = {workspace_id, scope}

    case :ets.lookup(@graph_table, key) do
      [{^key, json}] ->
        %{json: json, cached: true}

      [] ->
        GenServer.call(__MODULE__, {:build_graph, workspace_id, scope})
    end
  end

  @doc """
  Get a page by slug from cache, fetching from DB on miss.
  Returns `%Page{}` or `nil` (a cached miss is stored as `:not_found`).
  """
  def get_page(slug, workspace_id) do
    key = {slug, workspace_id}

    case :ets.lookup(@page_table, key) do
      [{^key, :not_found}] -> nil
      [{^key, page}] -> page
      [] -> GenServer.call(__MODULE__, {:fetch_page, slug, workspace_id})
    end
  end

  @doc """
  Invalidate the global graph cache for a context.

  Entries are keyed by `{workspace_id, scope}`, so a write invalidates every
  scope variant of the workspace (a match_delete on the workspace id).
  """
  def invalidate_context(workspace_id) do
    :ets.match_delete(@graph_table, {{workspace_id, :_}, :_})
    :ok
  end

  @doc "Invalidate the cached graph for a specific page."
  def invalidate_page(_page_id, workspace_id) do
    :ets.match_delete(@graph_table, {{workspace_id, :_}, :_})
    :ok
  end

  @doc "Invalidate a page cache entry by slug (used when slug changes)."
  def invalidate_page_slug(slug, workspace_id) do
    :ets.delete(@page_table, {slug, workspace_id})
    :ok
  end

  # ── GenServer callbacks ────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    # Create ETS tables owned by this GenServer.
    # read_concurrency enables lock-free reads from other processes.
    :ets.new(@graph_table, [:set, :named_table, :public, {:read_concurrency, true}])
    :ets.new(@page_table, [:set, :named_table, :public, {:read_concurrency, true}])
    {:ok, %{}}
  end

  # ── Global graph ──

  @impl true
  def handle_call({:build_graph, workspace_id, scope}, _from, state) do
    key = {workspace_id, scope}

    # Double-check after GenServer call (another process may have built it)
    case :ets.lookup(@graph_table, key) do
      [{^key, json}] ->
        {:reply, %{json: json, cached: true}, state}

      [] ->
        json = build_graph_json(workspace_id, scope)
        :ets.insert(@graph_table, {key, json})
        {:reply, %{json: json, cached: false}, state}
    end
  end

  # ── Page by slug ──

  @impl true
  def handle_call({:fetch_page, slug, workspace_id}, _from, state) do
    key = {slug, workspace_id}

    case :ets.lookup(@page_table, key) do
      [{^key, _} = entry] ->
        {:reply, elem(entry, 1), state}

      [] ->
        page = Knowledge.get_page_by_slug(slug, workspace_id)
        :ets.insert(@page_table, {key, page || :not_found})
        {:reply, page, state}
    end
  end

  # Ignore stray messages
  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # ── Payload building ───────────────────────────────────────────────────

  defp build_graph_json(workspace_id, scope) do
    %{nodes: raw_nodes, edges: raw_edges, total_nodes: total_nodes, total_edges: total_edges} =
      Knowledge.graph_data(workspace_id,
        exclude_types: @hidden_by_default,
        max_nodes: @max_graph_nodes,
        scope_pages: scope,
        scope_memory: scope
      )

    nodes =
      Enum.map(raw_nodes, fn n ->
        %{
          id: n.id,
          slug: n.slug,
          label: n.title,
          type: n.type,
          color: Map.get(GraphHelpers.type_colors(), n.type, GraphHelpers.fallback_color())
        }
      end)

    edges =
      Enum.map(raw_edges, fn e ->
        %{
          source_id: e.source,
          target_id: e.target,
          color: Map.get(GraphHelpers.edge_colors(), e.type, GraphHelpers.fallback_color())
        }
      end)

    type_counts = Knowledge.graph_type_counts(workspace_id, @hidden_by_default, scope)

    Jason.encode!(%{
      nodes: nodes,
      edges: edges,
      total_nodes: total_nodes,
      total_edges: total_edges,
      type_counts: type_counts,
      capped: total_nodes > length(nodes)
    })
  end
end
