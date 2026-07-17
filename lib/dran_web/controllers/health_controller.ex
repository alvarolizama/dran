defmodule DranWeb.HealthController do
  use DranWeb, :controller

  @doc "GET /health — public health check verifying DB connectivity"
  def show(conn, _params) do
    case Ecto.Adapters.SQL.query(Dran.Repo, "SELECT 1") do
      {:ok, _result} ->
        conn
        |> put_status(:ok)
        |> json(%{status: "ok", db: "up", timestamp: DateTime.utc_now()})

      {:error, _reason} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{status: "error", db: "down"})
    end
  end
end
