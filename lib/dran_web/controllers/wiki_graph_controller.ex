defmodule DranWeb.WikiGraphController do
  @moduledoc """
  Wiki-accessible JSON endpoint for the 3D graph.

  Serves the same ETS-cached payload as `GraphJSONController` (panel), but is
  accessible to ALL logged-in users — not just admins/editors. The panel's
  `/panel/graph-json` lives behind the `admin_or_editor` pipeline, which
  wiki-only users cannot pass; this controller sits under the wiki scope
  (`[:browser, :auth]`).

  The payload is cached in `Dran.GraphCache` (ETS-backed GenServer): the
  first request builds the graph, subsequent requests serve the cached JSON.
  """

  use DranWeb, :controller

  alias Dran.Brain
  alias Dran.GraphCache

  def show(conn, %{"context_slug" => context_slug}) do
    case Brain.get_context_by_slug(context_slug) do
      %{wiki_enabled: true} = context ->
        cached = GraphCache.get(context.id)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, cached.json)

      _ ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "context not found or wiki not enabled"})
    end
  end
end
