defmodule Dran.GraphCache do
  @moduledoc """
  In-memory cache for the global graph payload (nodes + edges + counts).

  The `/api/graph-json` endpoint and `GraphLive.index` share the same expensive
  query (Brain.graph_data + graph_type_counts). This GenServer caches the
  serialized JSON payload per context and serves it instantly on subsequent
  requests. The cache is invalidated on any `page_changed` PubSub broadcast
  for the context — a single process avoids concurrent redundant DB queries.
  """

  use GenServer

  alias Dran.Brain

  @hidden_by_default ~w(todo plan)
  @max_graph_nodes 400

  # ── Public API ─────────────────────────────────────────────────────────

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc """
  Get the cached graph JSON for a context, building it if missing.
  Returns `%{json: binary(), cached: boolean()}`.
  """
  def get(context_id), do: GenServer.call(__MODULE__, {:get, context_id})

  @doc "Force-invalidate the cache for a context (called on page_changed)."
  def invalidate(context_id), do: GenServer.cast(__MODULE__, {:invalidate, context_id})

  # ── GenServer callbacks ────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    # Cache invalidation is done via Dran.GraphCache.invalidate/1, called
    # directly from Brain.broadcast_page_change/3 — no PubSub subscription
    # needed (simpler, no race between broadcast and cache clear).
    {:ok, %{cache: %{}}}
  end

  @impl true
  def handle_call({:get, context_id}, _from, state) do
    case Map.get(state.cache, context_id) do
      nil ->
        # Cache miss — build and cache the payload
        payload = build_payload(context_id)
        new_state = put_in(state.cache[context_id], payload)
        {:reply, %{json: payload.json, cached: false}, new_state}

      cached ->
        {:reply, %{json: cached.json, cached: true}, state}
    end
  end

  @impl true
  def handle_cast({:invalidate, context_id}, state) do
    {:noreply, %{state | cache: Map.delete(state.cache, context_id)}}
  end

  # Ignore stray messages
  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # ── Payload building ───────────────────────────────────────────────────

  defp build_payload(context_id) do
    alias DranWeb.GraphHelpers

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

    json =
      Jason.encode!(%{
        nodes: nodes,
        edges: edges,
        total_nodes: total_nodes,
        total_edges: total_edges,
        type_counts: type_counts,
        capped: total_nodes > length(nodes)
      })

    %{json: json, nodes: length(nodes), edges: length(edges)}
  end
end
