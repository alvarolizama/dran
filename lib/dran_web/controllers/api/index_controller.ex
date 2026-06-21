defmodule DranWeb.API.IndexController do
  use DranWeb, :controller

  alias Dran.Brain

  @doc "GET /api/index?context=... — wiki index (all page slugs + titles)"
  def index(conn, %{"context" => context_slug}) do
    context = Brain.get_context_by_slug(context_slug)

    if context do
      pages = Brain.list_pages(context_id: context.id, limit: 10_000)

      index =
        Enum.map(pages, fn page ->
          %{slug: page.slug, title: page.title, type: page.page_type, tags: page.tags}
        end)

      json(conn, %{data: index})
    else
      conn
      |> put_status(:not_found)
      |> json(%{errors: %{detail: "context not found"}})
    end
  end

  def index(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{detail: "context query param is required"}})
  end
end
