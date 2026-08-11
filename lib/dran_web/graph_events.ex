defmodule DranWeb.GraphEvents do
  @moduledoc """
  Shared helpers for inline graph tab event handling.

  LiveViews call these from their `handle_event/3` clauses for the
  `switch_tab` and `node_click` events.
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
    push_navigate(socket, to: ~p"/panel/graph/#{slug}")
  end
end
