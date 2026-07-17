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
end
