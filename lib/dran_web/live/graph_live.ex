defmodule DranWeb.GraphLive do
  @moduledoc """
  LiveView for the knowledge graph.

  - `:index` renders the full graph of all pages and their relations.
  - `:show` renders a subgraph centered on a single page.

  The graph is rendered as SVG (nodes as circles, edges as lines) using a
  simple circular layout. Updates are pushed live via Phoenix.PubSub whenever
  a page is created, updated, or deleted.
  """

  use DranWeb, :live_view

  alias Dran.Brain
  alias DranWeb.GraphHelpers
  alias DranWeb.Plugs.Auth

  @impl true
  def mount(_params, session, socket) do
    {socket, context} = Auth.assign_to_socket(socket, session)

    if context do
      Phoenix.PubSub.subscribe(Dran.PubSub, "brain:#{context.id}")
    end

    {:ok,
     assign(socket,
       context: context,
       active_nav: "graph",
       page: nil,
       nodes: [],
       edges: [],
       type_colors: Enum.to_list(GraphHelpers.type_colors()),
       type_counts: %{},
       node_count: 0,
       edge_count: 0,
       view_mode: "2d"
     )}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(page: nil, page_title: "Knowledge Graph")
    |> load_index_graph()
  end

  defp apply_action(socket, :show, %{"slug" => slug}) do
    context = socket.assigns.context

    if context do
      case Brain.get_page_by_slug(slug, context.id) do
        nil ->
          push_navigate(socket, to: ~p"/graph")

        page ->
          socket
          |> assign(page: page, page_title: "Graph: #{page.title}")
          |> load_show_graph(page)
      end
    else
      push_navigate(socket, to: ~p"/graph")
    end
  end

  @impl true
  def handle_event("node_click", %{"slug" => slug}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/graph/#{slug}")}
  end

  @impl true
  def handle_event("toggle_view_mode", %{"mode" => mode}, socket)
      when mode in ["2d", "3d"] do
    {:noreply, assign(socket, view_mode: mode)}
  end

  @impl true
  def handle_event("node_drag", %{"id" => id, "x" => x, "y" => y}, socket) do
    nodes =
      Enum.map(socket.assigns.nodes, fn n ->
        if n.id == id, do: %{n | x: x, y: y}, else: n
      end)

    edges =
      Enum.map(socket.assigns.edges, fn e ->
        cond do
          e.source_id == id -> %{e | x1: x, y1: y}
          e.target_id == id -> %{e | x2: x, y2: y}
          true -> e
        end
      end)

    {:noreply, assign(socket, nodes: nodes, edges: edges)}
  end

  @impl true
  def handle_info({:page_changed, _action, _page}, socket) do
    {:noreply, load_graph_data(socket)}
  end

  # ── Data loading ───────────────────────────────────────────────────────────

  defp load_graph_data(socket) do
    case socket.assigns.live_action do
      :index ->
        load_index_graph(socket)

      :show ->
        case socket.assigns.page do
          nil -> socket
          page -> load_show_graph(socket, page)
        end
    end
  end

  defp load_index_graph(socket) do
    context = socket.assigns.context

    {nodes, edges} =
      if context do
        %{nodes: raw_nodes, edges: raw_edges} = Brain.graph_data(context.id)

        nodes =
          raw_nodes
          |> Enum.map(fn n ->
            %{
              id: n.id,
              slug: n.slug,
              label: n.title,
              type: n.type,
              color: Map.get(GraphHelpers.type_colors(), n.type, "#94A3B8"),
              radius: 12
            }
          end)
          |> GraphHelpers.circular_layout(400, 300, 250)

        positions = Map.new(nodes, fn n -> {n.id, {n.x, n.y}} end)

        edges =
          Enum.flat_map(raw_edges, fn e ->
            with {x1, y1} <- Map.get(positions, e.source),
                 {x2, y2} <- Map.get(positions, e.target) do
              [
                %{
                  source_id: e.source,
                  target_id: e.target,
                  x1: x1,
                  y1: y1,
                  x2: x2,
                  y2: y2,
                  color: Map.get(GraphHelpers.edge_colors(), e.type, "#94A3B8")
                }
              ]
            else
              _ -> []
            end
          end)

        {nodes, edges}
      else
        {[], []}
      end

    assign(socket,
      nodes: nodes,
      edges: edges,
      node_count: length(nodes),
      edge_count: length(edges),
      type_counts: count_types(nodes)
    )
  end

  defp load_show_graph(socket, page) do
    %{nodes: nodes, edges: edges} = GraphHelpers.build_page_subgraph(page)

    assign(socket,
      nodes: nodes,
      edges: edges,
      node_count: length(nodes),
      edge_count: length(edges),
      type_counts: count_types(nodes)
    )
  end

  defp count_types(nodes) do
    nodes
    |> Enum.group_by(& &1.type)
    |> Map.new(fn {type, ns} -> {type, length(ns)} end)
  end

  # ── Render ─────────────────────────────────────────────────────────────────

  defp graph_json(assigns) do
    nodes =
      Enum.map(assigns.nodes, fn n ->
        %{
          id: n.id,
          slug: n.slug,
          label: n.label,
          type: n.type,
          color: n.color
        }
      end)

    edges =
      Enum.map(assigns.edges, fn e ->
        %{
          source_id: e.source_id,
          target_id: e.target_id,
          color: e.color
        }
      end)

    Jason.encode!(%{nodes: nodes, edges: edges})
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_user={@current_user}
      context_slug={@context_slug}
      contexts={@contexts}
      active_nav={@active_nav}
    >
      <div class="p-6 overflow-y-auto">
        <h1 class="text-2xl font-bold mb-4">
          <div :if={@live_action == :index}>Knowledge Graph</div>
          <div :if={@live_action == :show and @page}>Graph: {@page.title}</div>
          <div :if={@live_action == :show and @page == nil}>Graph</div>
        </h1>

        <div class="flex gap-4">
          <div class="w-48 shrink-0">
            <h3 class="text-xs font-semibold text-base-content/40 uppercase mb-2">Types</h3>
            <div :for={{type, color} <- @type_colors} class="flex items-center gap-2 mb-1">
              <div class="w-3 h-3 rounded-full" style={"background: #{color}"}></div>
              <span class="text-sm capitalize flex-1">{type}</span>
              <span class="text-xs text-base-content/40 tabular-nums">
                {@type_counts[type] || 0}
              </span>
            </div>

            <h3 class="text-xs font-semibold text-base-content/40 uppercase mt-4 mb-2">Totals</h3>
            <div class="flex items-center gap-2 mb-1">
              <span class="text-sm flex-1">Nodes</span>
              <span class="text-xs text-base-content/40 tabular-nums">{@node_count}</span>
            </div>
            <div class="flex items-center gap-2 mb-1">
              <span class="text-sm flex-1">Edges</span>
              <span class="text-xs text-base-content/40 tabular-nums">{@edge_count}</span>
            </div>

            <h3 class="text-xs font-semibold text-base-content/40 uppercase mt-4 mb-2">View Mode</h3>
            <div class="join">
              <button
                class={[
                  "btn btn-xs join-item",
                  @view_mode == "2d" && "btn-primary",
                  @view_mode != "2d" && "btn-ghost"
                ]}
                phx-click="toggle_view_mode"
                phx-value-mode="2d"
              >
                2D
              </button>
              <button
                class={[
                  "btn btn-xs join-item",
                  @view_mode == "3d" && "btn-primary",
                  @view_mode != "3d" && "btn-ghost"
                ]}
                phx-click="toggle_view_mode"
                phx-value-mode="3d"
              >
                3D
              </button>
            </div>
          </div>

          <div class="flex-1 bg-base-200 rounded-lg overflow-hidden relative">
            <%= if @view_mode == "2d" do %>
              <svg
                id="graph-svg"
                width="100%"
                height="600"
                phx-hook="GraphPanZoom"
              >
                <line
                  :for={edge <- @edges}
                  x1={edge.x1}
                  y1={edge.y1}
                  x2={edge.x2}
                  y2={edge.y2}
                  stroke={edge.color}
                  stroke-width="1.5"
                  opacity="0.6"
                  data-source={edge.source_id}
                  data-target={edge.target_id}
                />

                <g
                  :for={node <- @nodes}
                  class="cursor-pointer"
                  phx-click="node_click"
                  phx-value-slug={node.slug}
                  data-node-id={node.id}
                  data-node-x={node.x}
                  data-node-y={node.y}
                >
                  <circle
                    cx={node.x}
                    cy={node.y}
                    r={node.radius}
                    fill={node.color}
                    stroke="white"
                    stroke-width="2"
                  />
                  <text
                    x={node.x}
                    y={node.y + node.radius + 15}
                    text-anchor="middle"
                    class="text-xs fill-current"
                  >
                    {node.label}
                  </text>
                </g>
              </svg>

              <div class="px-3 py-2 text-xs text-base-content/40 border-t border-base-300 bg-base-200/50">
                Scroll para zoom · Arrastra el fondo para moverte · Arrastra un nodo para reposicionar
              </div>
            <% else %>
              <div
                id="graph-3d"
                phx-hook="Graph3D"
                data-graph={graph_json(assigns)}
                style="width: 100%; height: 600px; background: #0f172a;"
              >
              </div>
              <div class="px-3 py-2 text-xs text-base-content/40 border-t border-base-300 bg-base-200/50">
                Arrastra para rotar · Scroll para zoom · Click-derecho para mover
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
