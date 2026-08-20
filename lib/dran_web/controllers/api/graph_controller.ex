defmodule DranWeb.API.GraphController do
  use DranWeb, :controller

  import Ecto.Query
  alias Dran.Repo
  alias Dran.{Page, Relation}

  @doc "GET /api/graph?context=... — full graph (nodes + edges)"
  def graph(conn, %{"workspace" => workspace_slug}) do
    with_context(conn, workspace_slug, fn conn, context ->
      nodes =
        Repo.all(
          from p in Page,
            where: p.workspace_id == ^context.id,
            select: %{id: p.id, title: p.title, slug: p.slug, type: p.page_type}
        )

      node_ids = Enum.map(nodes, & &1.id)

      edges =
        if Enum.empty?(node_ids) do
          []
        else
          Repo.all(
            from r in Relation,
              where: r.source_id in ^node_ids and r.target_id in ^node_ids,
              select: %{source: r.source_id, target: r.target_id, type: r.relation_type}
          )
        end

      json(conn, %{data: %{nodes: nodes, edges: edges}})
    end)
  end

  def graph(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{detail: "context query param is required"}})
  end
end
