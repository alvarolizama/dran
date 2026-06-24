defmodule DranWeb.API.SearchController do
  use DranWeb, :controller

  alias Dran.Brain

  @doc "GET /api/search?q=...&context=...&type=...&rerank=false"
  def search(conn, %{"q" => query} = params) do
    opts =
      []
      |> maybe_put(:context_id, resolve_context_id(params["context"]))
      |> maybe_put(:type, params["type"])
      |> maybe_put(:limit, params["limit"] && String.to_integer(params["limit"]))
      |> maybe_put(:rerank, parse_rerank(params["rerank"]))

    {:ok, results} = Brain.search(query, opts)

    json(conn, %{
      data:
        Enum.map(results, fn {page, excerpt} ->
          %{
            id: page.id,
            title: page.title,
            slug: page.slug,
            page_type: page.page_type,
            excerpt: excerpt,
            tags: page.tags
          }
        end)
    })
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
      |> maybe_put(:context_id, resolve_context_id(params["context"]))
      |> maybe_put(:limit, params["limit"] && String.to_integer(params["limit"]))

    {:ok, results} = Brain.fuzzy_search(query, opts)
    json(conn, %{data: results})
  end

  def fuzzy(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{detail: "q parameter is required"}})
  end

  @doc "GET /api/search/semantic?q=...&context=...&hybrid=true&rerank=false"
  def semantic(conn, %{"q" => query} = params) do
    opts =
      []
      |> maybe_put(:context_id, resolve_context_id(params["context"]))
      |> maybe_put(:type, params["type"])
      |> maybe_put(:limit, params["limit"] && String.to_integer(params["limit"]))
      |> maybe_put(:rerank, parse_rerank(params["rerank"]))

    results =
      if params["hybrid"] in ["true", "1"] do
        Brain.hybrid_search(query, opts)
      else
        Brain.semantic_search(query, opts)
      end

    case results do
      {:ok, data} ->
        json(conn, %{data: data})

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

  defp resolve_context_id(nil), do: nil

  defp resolve_context_id(slug) do
    case Brain.get_context_by_slug(slug) do
      nil -> nil
      context -> context.id
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, val), do: Keyword.put(opts, key, val)

  defp parse_rerank(nil), do: nil
  defp parse_rerank("true"), do: true
  defp parse_rerank("1"), do: true
  defp parse_rerank("false"), do: false
  defp parse_rerank("0"), do: false
  defp parse_rerank(_), do: nil
end
