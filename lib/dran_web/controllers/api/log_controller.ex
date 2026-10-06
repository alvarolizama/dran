defmodule DranWeb.API.LogController do
  use DranWeb, :controller

  alias Dran.Knowledge

  @doc "GET /api/log?context=...&action=...&limit=... — instancia-level activity."
  def index(conn, params) do
    # W5 (contract auditoria-fixes): el log es TELEMETRÍA de instancia (slugs,
    # tipos, autores de TODAS las páginas), no contenido compartible. Sin el
    # gate, un token `viewer` leía la actividad de páginas privadas ajenas.
    if Dran.ContentVisibility.privileged?(conn.assigns[:user], nil) do
      opts =
        []
        |> maybe_put(:workspace_id, DranWeb.API.Instance.instance_context_id())
        |> maybe_put(:action, params["action"])
        |> maybe_put(:limit, parse_limit(params["limit"]))

      logs = Knowledge.list_log(opts)
      json(conn, %{data: logs})
    else
      forbidden(conn)
    end
  end

  # W6 (contract auditoria-fixes): límite tolerante — el query string no
  # revienta 500 y se acota en SQL.
  defp parse_limit(nil), do: nil

  defp parse_limit(value) do
    case Integer.parse(to_string(value)) do
      {n, _} when n > 0 -> min(n, 100)
      _ -> nil
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, val), do: Keyword.put(opts, key, val)
end
