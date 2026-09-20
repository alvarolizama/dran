defmodule DranWeb.API.LogController do
  use DranWeb, :controller

  alias Dran.Knowledge

  @doc "GET /api/log?context=...&action=...&limit=..."
  def index(conn, params) do
    opts =
      []
      |> maybe_put(:workspace_id, DranWeb.API.Instance.instance_context_id())
      |> maybe_put(:action, params["action"])
      |> maybe_put(:limit, params["limit"] && String.to_integer(params["limit"]))

    logs = Knowledge.list_log(opts)
    json(conn, %{data: logs})
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, val), do: Keyword.put(opts, key, val)
end
