defmodule Dran.GraphCache do
  @moduledoc """
  ETS-backed cache for graph payloads, page subgraphs, and page lookups.

  Three cache tables, all with `read_concurrency: true`:

  | Table              | Key                          | Value                | Invalidated by           |
  |--------------------|------------------------------|----------------------|--------------------------|
  | `:dran_graph_cache`| `context_id`                 | global graph JSON    | `invalidate_context/1`  |
  | `:dran_subgraph`   | `{page_id, context_id}`      | subgraph map         | `invalidate_page/2`     |
  | `:dran_page_cache` | `{slug, context_id}`         | `%Page{}` or `nil`   | `invalidate_page/2`     |

  The GenServer owns the tables (creates them in `init/1`) and handles
  all writes (build + insert). Reads go directly to ETS — no GenServer
  call, no serialization, no bottleneck.

  Invalidation is triggered by `Brain.broadcast_page_change/3`:
    - `invalidate_context/1` wipes the global graph for the context
    - `invalidate_page/2` wipes the subgraph + page-cache entry for that page
  """

  use GenServer

  alias Dran.Brain
  alias DranWeb.GraphHelpers

  # Types hidden from the global graph (todo, plan, report) — the canonical
  # list lives in the Dran.Brain.PageTypes capability registry.
  @hidden_by_default Dran.Brain.PageTypes.hidden_from_graph()
  @max_graph_nodes 400

  # Tables
  @graph_table :dran_graph_cache
  @subgraph_table :dran_subgraph_cache
  @page_table :dran_page_cache

  # ── Public API ─────────────────────────────────────────────────────────

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc """
  Get the cached global graph JSON for a context, building if missing.
  Returns `%{json: binary(), cached: boolean()}`.
  Reads from ETS directly; on miss, calls the GenServer to build + cache.
  """
  def get(context_id) do
    case :ets.lookup(@graph_table, context_id) do
      [{^context_id, json}] ->
        %{json: json, cached: true}

      [] ->
        GenServer.call(__MODULE__, {:build_graph, context_id})
    end
  end

  @doc """
  Get the cached subgraph for a page, building if missing.
  Returns `%{nodes: list, edges: list}`.
  """
  def get_subgraph(page_id, context_id) do
    key = {page_id, context_id}

    case :ets.lookup(@subgraph_table, key) do
      [{^key, subgraph}] ->
        %{nodes: subgraph.nodes, edges: subgraph.edges, cached: true}

      [] ->
        GenServer.call(__MODULE__, {:build_subgraph, page_id, context_id})
    end
  end

  @doc """
  Get a page by slug from cache, fetching from DB on miss.
  Returns `%Page{}`, `nil`, or `{:error, :not_found}`.
  """
  def get_page(slug, context_id) do
    key = {slug, context_id}

    case :ets.lookup(@page_table, key) do
      [{^key, :not_found}] -> nil
      [{^key, page}] -> page
      [] -> GenServer.call(__MODULE__, {:fetch_page, slug, context_id})
    end
  end

  @doc "Invalidate the global graph cache for a context."
  def invalidate_context(context_id) do
    :ets.delete(@graph_table, context_id)
    :ok
  end

  @doc "Invalidate the subgraph + page cache for a specific page."
  def invalidate_page(page_id, context_id) do
    :ets.delete(@subgraph_table, {page_id, context_id})
    # Also invalidate the global graph since page data changed
    :ets.delete(@graph_table, context_id)
    :ok
  end

  @doc "Invalidate a page cache entry by slug (used when slug changes)."
  def invalidate_page_slug(slug, context_id) do
    :ets.delete(@page_table, {slug, context_id})
    :ok
  end

  @doc "Invalidate everything for a context (used on bulk operations)."
  def invalidate_all(context_id) do
    invalidate_context(context_id)
    # Clean subgraph entries for this context
    :ets.match_delete(@subgraph_table, {:_, context_id})
    # Clean page cache entries for this context
    :ets.match_delete(@page_table, {:_, context_id})
    :ok
  end

  # ── GenServer callbacks ────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    # Create ETS tables owned by this GenServer.
    # read_concurrency enables lock-free reads from other processes.
    :ets.new(@graph_table, [:set, :named_table, :public, {:read_concurrency, true}])
    :ets.new(@subgraph_table, [:set, :named_table, :public, {:read_concurrency, true}])
    :ets.new(@page_table, [:set, :named_table, :public, {:read_concurrency, true}])
    {:ok, %{}}
  end

  # ── Global graph ──

  @impl true
  def handle_call({:build_graph, context_id}, _from, state) do
    # Double-check after GenServer call (another process may have built it)
    case :ets.lookup(@graph_table, context_id) do
      [{^context_id, json}] ->
        {:reply, %{json: json, cached: true}, state}

      [] ->
        json = build_graph_json(context_id)
        :ets.insert(@graph_table, {context_id, json})
        {:reply, %{json: json, cached: false}, state}
    end
  end

  # ── Subgraph ──

  @impl true
  def handle_call({:build_subgraph, page_id, context_id}, _from, state) do
    key = {page_id, context_id}

    case :ets.lookup(@subgraph_table, key) do
      [{^key, subgraph}] ->
        {:reply, %{nodes: subgraph.nodes, edges: subgraph.edges, cached: true}, state}

      [] ->
        subgraph = build_subgraph(page_id, context_id)
        :ets.insert(@subgraph_table, {key, subgraph})
        {:reply, %{nodes: subgraph.nodes, edges: subgraph.edges, cached: false}, state}
    end
  end

  # ── Page by slug ──

  @impl true
  def handle_call({:fetch_page, slug, context_id}, _from, state) do
    key = {slug, context_id}

    case :ets.lookup(@page_table, key) do
      [{^key, _} = entry] ->
        {:reply, elem(entry, 1), state}

      [] ->
        page = Brain.get_page_by_slug(slug, context_id)
        :ets.insert(@page_table, {key, page || :not_found})
        {:reply, page, state}
    end
  end

  # Ignore stray messages
  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # ── Payload building ───────────────────────────────────────────────────

  defp build_graph_json(context_id) do
    %{nodes: raw_nodes, edges: raw_edges, total_nodes: total_nodes, total_edges: total_edges} =
      Brain.graph_data(context_id, exclude_types: @hidden_by_default, max_nodes: @max_graph_nodes)

    nodes =
      Enum.map(raw_nodes, fn n ->
        %{
          id: n.id,
          slug: n.slug,
          label: n.title,
          type: n.type,
          color: Map.get(GraphHelpers.type_colors(), n.type, "#94A3B8")
        }
      end)

    edges =
      Enum.map(raw_edges, fn e ->
        %{
          source_id: e.source,
          target_id: e.target,
          color: Map.get(GraphHelpers.edge_colors(), e.type, "#94A3B8")
        }
      end)

    type_counts = Brain.graph_type_counts(context_id, @hidden_by_default)

    Jason.encode!(%{
      nodes: nodes,
      edges: edges,
      total_nodes: total_nodes,
      total_edges: total_edges,
      type_counts: type_counts,
      capped: total_nodes > length(nodes)
    })
  end

  defp build_subgraph(page_id, _context_id) do
    page = Brain.get_page!(page_id)
    %{nodes: nodes, edges: edges} = GraphHelpers.build_page_subgraph(page)
    %{nodes: nodes, edges: edges}
  end
end
