defmodule DranWeb.API.LintController do
  use DranWeb, :controller

  alias Dran.Brain

  @doc "GET /api/lint?context=..."
  def lint(conn, %{"context" => context_slug}) do
    context = Brain.get_context_by_slug(context_slug)

    if context do
      report = Brain.lint(context.id)
      json(conn, %{data: report})
    else
      conn
      |> put_status(:not_found)
      |> json(%{errors: %{detail: "context not found"}})
    end
  end

  def lint(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{detail: "context query param is required"}})
  end
end
