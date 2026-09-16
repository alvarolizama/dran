defmodule DranWeb.API.ExportController do
  use DranWeb, :controller

  alias Dran.Exporter

  @doc "GET /api/workspaces/:slug/export — export context as JSON (visibility-filtered)"
  def show(conn, %{"slug" => slug}) do
    scope = export_scope(conn, slug)

    case Exporter.export_context(slug, scope: scope) do
      {:ok, data} ->
        json(conn, data)

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{errors: %{detail: "context not found"}})
    end
  end

  @doc """
  GET /api/export/:workspace/full — full export of a context by id.

  Returns JSON with a `content-disposition: attachment` header so the
  response can be saved as a file. The body contains context, pages,
  relations, and page versions.
  """
  def full(conn, %{"workspace" => workspace_id}) do
    # SEC-009: validate the user has access to this context before exporting
    user = conn.assigns[:user]

    if user && (user.is_owner or user_has_context_access?(user, workspace_id)) do
      scope = Dran.ContentVisibility.resolve(workspace_id, user, :pages)

      case Exporter.full_export(workspace_id, scope: scope) do
        {:ok, data} ->
          filename = "dran-export-#{workspace_id}.json"

          conn
          |> put_resp_header("content-disposition", "attachment; filename=\"#{filename}\"")
          |> json(data)

        {:error, :not_found} ->
          conn
          |> put_status(:not_found)
          |> json(%{errors: %{detail: "context not found"}})
      end
    else
      conn
      |> put_status(:forbidden)
      |> json(%{errors: %{detail: "access to context denied"}})
    end
  end

  # Single authorization policy (SEC-001 read access).
  defp user_has_context_access?(user, workspace_id) do
    DranWeb.ResourceAuthorization.authorize(user, :read, workspace_id) == :ok
  end

  # El scope del export sale del módulo único de política (slug → workspace).
  defp export_scope(conn, slug) do
    Dran.ContentVisibility.resolve(slug, conn.assigns[:user], :pages)
  end
end
