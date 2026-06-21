defmodule DranWeb.API.SearchController do
  use DranWeb, :controller

  alias Dran.Brain

  @doc "GET /api/search?q=...&context=...&type=..."
  def search(conn, %{"q" => query} = params) do
    opts =
      []
      |> maybe_put(:context_id, resolve_context_id(params["context"]))
      |> maybe_put(:type, params["type"])
      |> maybe_put(:limit, params["limit"] && String.to_integer(params["limit"]))

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

  defp resolve_context_id(nil), do: nil

  defp resolve_context_id(slug) do
    case Brain.get_context_by_slug(slug) do
      nil -> nil
      context -> context.id
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, val), do: Keyword.put(opts, key, val)
end
