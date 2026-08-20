defmodule DranWeb.API.LintController do
  use DranWeb, :controller

  alias Dran.Brain

  @doc "GET /api/lint?context=..."
  def lint(conn, %{"workspace" => workspace_slug}) do
    with_context(conn, workspace_slug, fn conn, context ->
      json(conn, %{data: Brain.lint(context.id)})
    end)
  end

  def lint(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{detail: "context query param is required"}})
  end
end
