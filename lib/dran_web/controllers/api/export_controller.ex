defmodule DranWeb.API.ExportController do
  use DranWeb, :controller

  alias Dran.Exporter

  @doc "GET /api/contexts/:slug/export — export context as JSON"
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
  GET /api/export/:context/full — full export of a context by id.

  Returns JSON with a `content-disposition: attachment` header so the
  response can be saved as a file. The body contains context, pages,
  relations, and page versions.
  """
  def full(conn, %{"context" => context_id}) do
    case Exporter.full_export(context_id) do
      {:ok, data} ->
        filename = "dran-export-#{context_id}.json"

        conn
        |> put_resp_header("content-disposition", "attachment; filename=\"#{filename}\"")
        |> json(data)

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{errors: %{detail: "context not found"}})
    end
  end
end
