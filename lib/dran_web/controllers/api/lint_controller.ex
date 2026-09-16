defmodule DranWeb.API.LintController do
  use DranWeb, :controller

  alias Dran.Knowledge

  @doc "GET /api/lint?context=... — structural hygiene audit (visibility-filtered)"
  def lint(conn, %{"workspace" => workspace_slug}) do
    with_context(conn, workspace_slug, fn conn, context ->
      scope = Dran.ContentVisibility.resolve(context, conn.assigns[:user], :pages)
      json(conn, %{data: Knowledge.lint(context.id, scope: scope)})
    end)
  end

  def lint(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{detail: "context query param is required"}})
  end
end
