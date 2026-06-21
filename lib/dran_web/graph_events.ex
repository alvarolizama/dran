defmodule DranWeb.GraphEvents do
  @moduledoc """
  Shared helpers for inline graph tab event handling.

  LiveViews call these from their `handle_event/3` clauses for the
  `switch_tab`, `node_click`, and `node_drag` events.
  """

  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [push_navigate: 2]

  use Phoenix.VerifiedRoutes,
    endpoint: DranWeb.Endpoint,
    router: DranWeb.Router,
    statics: DranWeb.static_paths()

  def switch_tab(socket, tab) do
    assign(socket, active_tab: tab)
  end

  def node_click(socket, slug) do
    push_navigate(socket, to: ~p"/graph/#{slug}")
  end

  def node_drag(socket, id, x, y) do
    graph_nodes =
      Enum.map(socket.assigns[:graph_nodes] || [], fn n ->
        if n.id == id, do: %{n | x: x, y: y}, else: n
      end)

    graph_edges =
      Enum.map(socket.assigns[:graph_edges] || [], fn e ->
        cond do
          e.source_id == id -> %{e | x1: x, y1: y}
          e.target_id == id -> %{e | x2: x, y2: y}
          true -> e
        end
      end)

    assign(socket, graph_nodes: graph_nodes, graph_edges: graph_edges)
  end
end
