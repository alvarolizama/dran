defmodule DranWeb.GraphJSONController do
  @moduledoc """
  Session-authenticated JSON endpoint for the 3D graph.

  The LiveView `/graph` page loads its shell immediately, then the Graph3D
  hook fetches the actual node/edge data from this endpoint via HTTP. This
  keeps the initial page load instant even on large brains — the expensive
  query happens asynchronously after the UI is already responsive.
  """
  use DranWeb, :controller

  alias Dran.Brain
  alias DranWeb.GraphHelpers
  alias DranWeb.Plugs.Auth

  # Page types excluded from the global graph (mirrors GraphLive)
  @hidden_by_default ~w(todo plan)

  def show(conn, params) do
    context_slug = Auth.current_context(conn)
    context = Brain.get_context_by_slug(context_slug)

    if context do
      max_nodes =
        params
        |> Map.get("max_nodes", "400")
        |> String.to_integer()
        |> min(1000)
        |> max(50)

      %{nodes: raw_nodes, edges: raw_edges, total_nodes: total_nodes, total_edges: total_edges} =
        Brain.graph_data(context.id, exclude_types: @hidden_by_default, max_nodes: max_nodes)

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

      type_counts = Brain.graph_type_counts(context.id, @hidden_by_default)

      json(conn, %{
        nodes: nodes,
        edges: edges,
        total_nodes: total_nodes,
        total_edges: total_edges,
        type_counts: type_counts,
        capped: total_nodes > length(nodes)
      })
    else
      conn
      |> put_status(:unauthorized)
      |> json(%{error: "context required"})
    end
  end
end
