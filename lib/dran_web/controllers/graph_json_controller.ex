defmodule DranWeb.GraphJSONController do
  @moduledoc """
  Session-authenticated JSON endpoint for the 3D graph.

  The LiveView `/graph` page loads its shell immediately, then the Graph3D
  hook fetches the actual node/edge data from this endpoint via HTTP. This
  keeps the initial page load instant even on large brains — the expensive
  query happens asynchronously after the UI is already responsive.

  The payload is cached in `Dran.GraphCache` (ETS-backed GenServer): the
  first request builds the graph, subsequent requests serve the cached JSON
  instantly. The cache is invalidated on any `page_changed` PubSub broadcast.
  """

  use DranWeb, :controller

  alias Dran.Knowledge
  alias DranWeb.Plugs.Auth

  def show(conn, _params) do
    workspace_slug = Auth.current_context(conn)
    context = Knowledge.get_workspace_by_slug(workspace_slug)

    if context do
      # Serve from cache (ETS-backed GenServer). First hit builds the payload
      # from Knowledge.graph_data; subsequent hits return the cached JSON.
      cached = Dran.GraphCache.get(context.id)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, cached.json)
    else
      conn
      |> put_status(:unauthorized)
      |> json(%{error: "context required"})
    end
  end
end
