defmodule DranWeb.HomeGraphController do
  @moduledoc """
  Instance graph JSON endpoint for the 3D graph (single-workspace model, W1).

  Accessible to all logged-in users. The payload is cached in `Dran.GraphCache`
  (ETS-backed GenServer): the first request builds the graph, subsequent
  requests serve the cached JSON.
  """

  use DranWeb, :controller

  alias Dran.GraphCache

  def show(conn, _params) do
    case Dran.Auth.instance_workspace() do
      %{id: workspace_id} = context ->
        # El grafo se cachea POR SCOPE: el lector pide su propia vista.
        scope = Dran.ContentVisibility.resolve(context, conn.assigns[:user], :pages)
        cached = GraphCache.get(workspace_id, scope)

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
