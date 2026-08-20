defmodule DranWeb.API.ExportController do
  use DranWeb, :controller

  alias Dran.Exporter

  @doc "GET /api/workspaces/:slug/export — export context as JSON"
  def show(conn, %{"slug" => slug}) do
    case Exporter.export_context(slug) do
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
      case Exporter.full_export(workspace_id) do
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

  defp user_has_context_access?(%{contexts: :all}, _workspace_id), do: true

  defp user_has_context_access?(%{contexts: contexts}, workspace_id) when is_list(contexts) do
    Enum.any?(contexts, &(&1.id == workspace_id))
  end

  defp user_has_context_access?(_, _), do: false
end
