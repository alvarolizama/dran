defmodule DranWeb.HomeGraphController do
  @moduledoc """
  Workspace-scoped JSON endpoint for the 3D graph.

  Accessible to all logged-in users with access to the workspace. The payload
  is cached in `Dran.GraphCache` (ETS-backed GenServer): the first request
  builds the graph, subsequent requests serve the cached JSON.
  """

  use DranWeb, :controller

  alias Dran.Knowledge
  alias Dran.GraphCache

  def show(conn, %{"workspace_slug" => workspace_slug}) do
    case Knowledge.get_workspace_by_slug(workspace_slug) do
      %{} = context ->
        cached = GraphCache.get(context.id)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, cached.json)

      _ ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "context not found"})
    end
  end
end
