defmodule DranWeb.API.SearchController do
  use DranWeb, :controller

  alias Dran.Brain

  @doc "GET /api/search?q=...&context=...&type=...&strategy=...&rerank=false"
  def search(conn, %{"q" => query} = params) do
    case resolve_context_id(params["context"]) do
      :error ->
        conn
        |> put_status(:not_found)
        |> json(%{errors: %{detail: "context not found"}})

      context_id ->
        opts =
          []
          |> maybe_put(:context_id, context_id)
          |> maybe_put(:type, params["type"])
          |> maybe_put(:limit, params["limit"] && String.to_integer(params["limit"]))
          |> maybe_put(:strategy, parse_strategy(params["strategy"]))
          |> maybe_put(:rerank, parse_rerank(params["rerank"]))

        case Brain.search(query, opts) do
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
  end

  def search(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{detail: "q parameter is required"}})
  end

  @doc "GET /api/search/fuzzy?q=...&context=..."
  def fuzzy(conn, %{"q" => query} = params) do
    case resolve_context_id(params["context"]) do
      :error ->
        conn
        |> put_status(:not_found)
        |> json(%{errors: %{detail: "context not found"}})

      context_id ->
        opts =
          []
          |> maybe_put(:context_id, context_id)
          |> maybe_put(:limit, params["limit"] && String.to_integer(params["limit"]))

        case Brain.search(query, Keyword.put(opts, :strategy, :fuzzy)) do
          {:ok, results} -> json(conn, %{data: results})
          {:error, reason} -> json(conn, %{errors: %{detail: inspect(reason)}})
        end
    end
  end

  def fuzzy(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{detail: "q parameter is required"}})
  end

  @doc "GET /api/search/semantic?q=...&context=...&strategy=...&rerank=false"
  def semantic(conn, %{"q" => query} = params) do
    case resolve_context_id(params["context"]) do
      :error ->
        conn
        |> put_status(:not_found)
        |> json(%{errors: %{detail: "context not found"}})

      context_id ->
        opts =
          []
          |> maybe_put(:context_id, context_id)
          |> maybe_put(:type, params["type"])
          |> maybe_put(:limit, params["limit"] && String.to_integer(params["limit"]))
          |> maybe_put(:rerank, parse_rerank(params["rerank"]))

        strategy = if params["hybrid"] in ["true", "1"], do: :hybrid, else: :semantic

        case Brain.search(query, Keyword.put(opts, :strategy, strategy)) do
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
  end

  def semantic(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{detail: "q parameter is required"}})
  end

  defp resolve_context_id(nil), do: nil

  defp resolve_context_id(slug) do
    # SEC-012: fail closed — return :error for unknown contexts instead of nil
    # (nil would mean "search all contexts" which is a fail-open IDOR)
    case Brain.get_context_by_slug(slug) do
      nil -> :error
      context -> context.id
    end
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

  defp parse_rerank(nil), do: nil
  defp parse_rerank("true"), do: true
  defp parse_rerank("1"), do: true
  defp parse_rerank("false"), do: false
  defp parse_rerank("0"), do: false
  defp parse_rerank(_), do: nil
end
