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

  # Page types excluded from the global 3D graph entirely: the operational
  # layer (todos, plans) whose ephemeral leaf nodes would flood the graph
  # with work-in-progress noise. They are left out of the sidebar type list
  # (no toggle to bring them back) AND the rendered graph. They remain
  # visible in the per-page subgraph (graph tab + /graph/:slug), where local
  # context matters.
  @hidden_by_default ~w(todo plan)

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
       # Wave 2: data no longer crosses the socket in index mode — the hook
       # fetches /api/graph-json and filters client-side. The LV only holds
       # counters, visible_types and, in show mode, the small subgraph.
       # Show mode carries the small subgraph in the socket (data-graph);
       # all_nodes/all_edges hold the unfiltered source so toggle_type is
       # non-destructive. Index mode doesn't use them (the hook owns the data).
       nodes: [],
       edges: [],
       all_nodes: [],
       all_edges: [],
       visible_types: default_visible_types(),
       type_colors: sidebar_type_colors(),
       type_counts: %{},
       node_count: 0,
       edge_count: 0,
       total_node_count: 0,
       total_edge_count: 0,
       # Wave 3: debounce timer handle for page_changed re-fetches in index.
       refetch_timer: nil,
       loading: false
     )}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(page: nil, page_title: gettext("Knowledge Graph"), loading: true)

    # Progressive: no data load here — the Graph3D hook fetches /api/graph-json
    # via HTTP after the shell renders, keeping initial page load instant.
  end

  defp apply_action(socket, :show, %{"slug" => slug}) do
    context = socket.assigns.context

    if context do
      case Brain.get_page_by_slug(slug, context.id) do
        nil ->
          push_navigate(socket, to: ~p"/graph")

        page ->
          socket
          |> assign(page: page, page_title: gettext("Graph: %{title}", title: page.title))
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
  def handle_event("toggle_type", %{"type" => type}, socket) do
    visible =
      if MapSet.member?(socket.assigns.visible_types, type) do
        MapSet.delete(socket.assigns.visible_types, type)
      else
        MapSet.put(socket.assigns.visible_types, type)
      end

    socket = assign(socket, visible_types: visible)

    case socket.assigns.live_action do
      # Wave 2: in index the hook owns the data — tell it which types to show
      # and let it filter client-side (no socket roundtrip of nodes/edges).
      :index ->
        {:noreply, push_event(socket, "set_visible_types", %{types: MapSet.to_list(visible)})}

      # Show mode still carries the small subgraph in the socket (data-graph),
      # so the server filters it as before.
      :show ->
        {:noreply, filter_visible(socket)}
    end
  end

  @impl true
  def handle_event(
        "graph_loaded",
        %{
          "total_nodes" => total_nodes,
          "total_edges" => total_edges,
          "type_counts" => type_counts
        },
        socket
      ) do
    # Wave 2: the progressive fetch pushes only counters — the graph data
    # itself stays in the hook's fullData and never crosses the socket.
    {:noreply,
     assign(socket,
       type_counts: type_counts || %{},
       total_node_count: total_nodes || 0,
       total_edge_count: total_edges || 0,
       loading: false
     )}
  end

  # Wave 2: after the hook filters client-side (initial load or a type toggle),
  # it reports the visible counts so the sidebar stays accurate.
  @impl true
  def handle_event(
        "graph_counts",
        %{"node_count" => node_count, "edge_count" => edge_count},
        socket
      ) do
    {:noreply, assign(socket, node_count: node_count || 0, edge_count: edge_count || 0)}
  end

  @impl true
  def handle_info({:page_changed, _action, changed_page}, socket) do
    case socket.assigns.live_action do
      :index ->
        # Wave 3: debounce broadcasts — a rapid burst of page_changed should
        # collapse into a single re-fetch. Cancel any pending timer first,
        # then schedule one; when it fires we tell the hook to re-fetch.
        if socket.assigns.refetch_timer do
          Process.cancel_timer(socket.assigns.refetch_timer)
        end

        timer = Process.send_after(self(), :graph_refetch, 1500)
        {:noreply, assign(socket, refetch_timer: timer)}

      :show ->
        page = socket.assigns.page

        if page && page_changed_affects_subgraph?(page.id, changed_page, socket) do
          {:noreply, load_show_graph(socket, page)}
        else
          {:noreply, socket}
        end
    end
  end

  # Wave 3: debounce elapsed — mark the graph stale and tell the hook to
  # re-fetch /api/graph-json. The full graph is never re-serialized over the
  # socket on every broadcast anymore.
  @impl true
  def handle_info(:graph_refetch, socket) do
    {:noreply, assign(socket, refetch_timer: nil) |> push_event("graph_refetch", %{})}
  end

  # ── Data loading ───────────────────────────────────────────────────────────

  # Restrict the rendered nodes/edges to the currently visible types. Edges
  # whose endpoints are both hidden are dropped too, so the 3D view never
  # draws a line pointing at a node that isn't there. Used by show mode where
  # the small subgraph still lives in the socket. Filters from all_nodes/
  # all_edges (the unfiltered source) so toggling is non-destructive.
  defp filter_visible(socket) do
    visible = socket.assigns.visible_types

    nodes = Enum.filter(socket.assigns.all_nodes, &MapSet.member?(visible, &1.type))
    visible_ids = MapSet.new(nodes, & &1.id)

    edges =
      Enum.filter(socket.assigns.all_edges, fn e ->
        MapSet.member?(visible_ids, e.source_id) and MapSet.member?(visible_ids, e.target_id)
      end)

    assign(socket,
      nodes: nodes,
      edges: edges,
      node_count: length(nodes),
      edge_count: length(edges)
    )
  end

  # Everything except the operational layer. Declarative: add a type to
  # @hidden_by_default and it stops cluttering the global graph.
  defp default_visible_types do
    GraphHelpers.type_colors()
    |> Map.keys()
    |> MapSet.new()
    |> MapSet.difference(MapSet.new(@hidden_by_default))
  end

  # The sidebar lists only the types that can actually appear in the graph —
  # the operational layer is left out entirely, so there's no toggle to
  # bring todos/plans back into the global view.
  defp sidebar_type_colors do
    GraphHelpers.type_colors()
    |> Enum.reject(fn {type, _color} -> type in @hidden_by_default end)
  end

  defp load_show_graph(socket, page) do
    %{nodes: nodes, edges: edges} = Dran.GraphCache.get_subgraph(page.id, page.context_id)

    # Show mode: all types visible (including the operational layer — the
    # subgraph is local context, not the global filtered view).
    visible_types = MapSet.new(nodes, & &1.type)

    socket
    |> assign(
      all_nodes: nodes,
      all_edges: edges,
      visible_types: visible_types,
      type_counts: count_types(nodes)
    )
    |> filter_visible()
  end

  defp count_types(nodes) do
    nodes
    |> Enum.group_by(& &1.type)
    |> Map.new(fn {type, ns} -> {type, length(ns)} end)
  end

  # Only reload the subgraph when the changed page is the center or a direct
  # neighbor of the current view — avoid wasteful 3-query reload on every
  # PubSub broadcast for unrelated pages in the same context.
  defp page_changed_affects_subgraph?(center_id, changed_page, socket) do
    changed_page.id == center_id ||
      Enum.any?(socket.assigns.nodes, &(&1.id == changed_page.id))
  end

  # ── Render ─────────────────────────────────────────────────────────────────

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
      <div class="flex flex-col flex-1 min-h-0">
        <div class="shrink-0 p-4 pb-0">
          <h1 class="text-title">
            <div :if={@live_action == :index}>{gettext("Knowledge Graph")}</div>
            <div :if={@live_action == :show and @page}>
              {gettext("Graph: %{title}", title: @page.title)}
            </div>
            <div :if={@live_action == :show and @page == nil}>{gettext("Graph")}</div>
          </h1>
          <p class="text-caption mt-1">
            {gettext(
              "Visualize how your pages connect. Drag to rotate, hover a node to reveal labels, click a node to navigate."
            )}
          </p>
        </div>

        <div class="flex gap-4 flex-1 min-h-0">
          <div class="w-48 shrink-0 p-2">
            <h3 class="text-xs font-semibold text-base-content/40 uppercase mb-2">
              {gettext("Types")}
            </h3>
            <button
              :for={{type, color} <- @type_colors}
              type="button"
              phx-click="toggle_type"
              phx-value-type={type}
              class={[
                "flex w-full items-center gap-2 rounded px-1 py-0.5 text-left transition",
                if(MapSet.member?(@visible_types, type),
                  do: "hover:bg-base-200",
                  else: "opacity-40 hover:opacity-70"
                )
              ]}
            >
              <div
                class="w-3 h-3 shrink-0 rounded-full"
                style={"background: #{if MapSet.member?(@visible_types, type), do: color, else: "#64748B"}"}
              >
              </div>
              <span class="text-sm capitalize flex-1">{type}</span>
              <span class="text-xs text-base-content/40 tabular-nums">
                {@type_counts[type] || 0}
              </span>
            </button>

            <h3 class="text-xs font-semibold text-base-content/40 uppercase mt-4 mb-2">
              {gettext("Totals")}
            </h3>
            <div class="flex items-center gap-2 mb-1">
              <span class="text-sm flex-1">{gettext("Nodes")}</span>
              <span class="text-xs text-base-content/40 tabular-nums">{@node_count}</span>
            </div>
            <div class="flex items-center gap-2 mb-1">
              <span class="text-sm flex-1">{gettext("Edges")}</span>
              <span class="text-xs text-base-content/40 tabular-nums">{@edge_count}</span>
            </div>
          </div>

          <div class="flex-1 overflow-hidden relative">
            <div
              :if={@live_action == :index and @loading}
              class="absolute inset-0 z-20 flex items-center justify-center bg-base-100/80 backdrop-blur-sm"
            >
              <div class="flex flex-col items-center gap-3">
                <div class="loading loading-spinner loading-lg text-primary"></div>
                <p class="text-sm text-base-content/60">{gettext("Loading graph...")}</p>
              </div>
            </div>
            <div
              :if={@live_action == :index and not @loading and @total_node_count > @node_count}
              class="absolute top-2 left-1/2 -translate-x-1/2 z-10 max-w-[90%] rounded-lg bg-base-100/90 border border-base-300 px-3 py-1.5 text-xs text-base-content/70 shadow-sm backdrop-blur"
            >
              {gettext(
                "Showing the %{shown} most-connected nodes of %{total} — search for a page to explore its subgraph.",
                shown: @node_count,
                total: @total_node_count
              )}
            </div>
            <.graph_3d
              id="graph-3d"
              nodes={@nodes}
              edges={@edges}
              visible_types={if @live_action == :index, do: MapSet.to_list(@visible_types), else: nil}
              class="w-full h-full"
            />
            <div class="absolute bottom-0 left-0 right-0 px-3 py-2 text-xs text-base-content/40 bg-base-200/50 border-t border-base-300">
              {gettext("Drag to rotate · Scroll to zoom · Hover to highlight · Click to navigate")}
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
