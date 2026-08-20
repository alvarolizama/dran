defmodule DranWeb.API.IndexController do
  use DranWeb, :controller

  alias Dran.Brain

  @doc "GET /api/index?context=... — wiki index (all page slugs + titles)"
  def index(conn, %{"workspace" => workspace_slug}) do
    with_context(conn, workspace_slug, fn conn, context ->
      pages = Brain.list_pages(workspace_id: context.id, limit: 10_000)

      index =
        Enum.map(pages, fn page ->
          %{
            slug: page.slug,
            title: page.title,
            type: page.page_type,
            tags: page.tags,
            status: page.meta["status"],
            kanban_status: page.meta["kanban_status"],
            progress: page.meta["progress"],
            archived: page.archived
          }
        end)

      json(conn, %{data: index})
    end)
  end

  def index(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{detail: "context query param is required"}})
  end
end
