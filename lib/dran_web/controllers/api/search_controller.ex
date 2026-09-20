defmodule DranWeb.API.SearchController do
  use DranWeb, :controller

  alias Dran.Knowledge

  @doc "GET /api/search?q=...&context=...&type=...&strategy=..."
  def search(conn, %{"q" => query} = params) do
    # W5: the instance IS the workspace — the legacy context param is ignored.
    workspace_id = DranWeb.API.Instance.instance_context_id()

    opts =
      []
      |> maybe_put(:workspace_id, workspace_id)
      |> maybe_put(:type, params["type"])
      |> maybe_put(:limit, params["limit"] && String.to_integer(params["limit"]))
      |> maybe_put(:strategy, parse_strategy(params["strategy"]))
      |> Keyword.put(:scope, DranWeb.API.Instance.scope_for(conn, :pages))

    case Knowledge.search(query, opts) do
      {:ok, results} ->
        json(conn, %{data: results})

      {:error, :not_configured} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{errors: %{detail: "Inference API is not configured"}})

      {:error, reason} ->
        conn
        |> put_status(:bad_gateway)
        |> json(%{errors: %{detail: inspect(reason)}})
    end
  end

  def search(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{detail: "q parameter is required"}})
  end

  @doc "GET /api/search/fuzzy?q=...&context=..."
  def fuzzy(conn, %{"q" => query} = params) do
    opts =
      []
      |> maybe_put(:workspace_id, DranWeb.API.Instance.instance_context_id())
      |> maybe_put(:limit, params["limit"] && String.to_integer(params["limit"]))
      |> Keyword.put(:scope, DranWeb.API.Instance.scope_for(conn, :pages))

    case Knowledge.search(query, Keyword.put(opts, :strategy, :fuzzy)) do
      {:ok, results} -> json(conn, %{data: results})
      {:error, reason} -> json(conn, %{errors: %{detail: inspect(reason)}})
    end
  end

  def fuzzy(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{detail: "q parameter is required"}})
  end

  @doc "GET /api/search/semantic?q=...&context=...&strategy=..."
  def semantic(conn, %{"q" => query} = params) do
    opts =
      []
      |> maybe_put(:workspace_id, DranWeb.API.Instance.instance_context_id())
      |> maybe_put(:type, params["type"])
      |> maybe_put(:limit, params["limit"] && String.to_integer(params["limit"]))
      |> Keyword.put(:scope, DranWeb.API.Instance.scope_for(conn, :pages))

    strategy = if params["hybrid"] in ["true", "1"], do: :hybrid, else: :semantic

    case Knowledge.search(query, Keyword.put(opts, :strategy, strategy)) do
      {:ok, results} ->
        json(conn, %{data: results})

      {:error, :not_configured} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{errors: %{detail: "Inference API is not configured"}})

      {:error, reason} ->
        conn
        |> put_status(:bad_gateway)
        |> json(%{errors: %{detail: inspect(reason)}})
    end
  end

  def semantic(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{detail: "q parameter is required"}})
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, val), do: Keyword.put(opts, key, val)

  defp parse_strategy(nil), do: nil
  defp parse_strategy("fts"), do: :fts
  defp parse_strategy("fuzzy"), do: :fuzzy
  defp parse_strategy("semantic"), do: :semantic
  defp parse_strategy("hybrid"), do: :hybrid
  defp parse_strategy("auto"), do: :auto
  defp parse_strategy(_), do: nil
end
