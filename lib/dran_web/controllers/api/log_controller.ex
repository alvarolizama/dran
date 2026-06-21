defmodule DranWeb.API.LogController do
  use DranWeb, :controller

  alias Dran.Brain

  @doc "GET /api/log?context=...&action=...&limit=..."
  def index(conn, params) do
    opts =
      []
      |> maybe_put(:context_id, resolve_context_id(params["context"]))
      |> maybe_put(:action, params["action"])
      |> maybe_put(:limit, params["limit"] && String.to_integer(params["limit"]))

    logs = Brain.list_log(opts)
    json(conn, %{data: logs})
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
