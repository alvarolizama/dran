defmodule DranWeb.API.ServiceController do
  @moduledoc """
  REST API de SERVICIOS: la única puerta de la superficie de Composio.

  La identidad la pone `require_api_token/2` en `conn.assigns[:user]` y NADA de
  aquí la acepta del cliente: ninguna acción lee `user_id` ni `session_id` de
  los params. El `agent_name` sale del header `X-Hermes-Agent` en el mismo punto
  único donde se resuelve para el resto del REST.

  El cliente HTTP de Composio vive en `Dran.Composio` y la política en
  `Dran.Services`: este controlador traduce HTTP a contexto y contexto a HTTP,
  con los errores tipados (`:not_configured`, `:not_allowed`, `{:composio, s, b}`)
  mapeados a códigos explícitos.
  """

  use DranWeb, :controller

  alias Dran.Services

  @doc """
  GET /api/services — los servicios de la instancia (allowlist del owner) con el
  estado real de lo que ESTE lector tiene conectado.

  Sin key de instancia responde 200 con `configured: false` (no es un error del
  cliente: la integración está apagada) para que el agente lo lea como dato.
  """
  def index(conn, _params) do
    case Services.list_services(conn.assigns[:user]) do
      {:ok, services} ->
        json(conn, %{data: services, configured: true})

      {:error, :not_configured} ->
        json(conn, %{data: [], configured: false})

      {:error, reason} ->
        failure(conn, reason)
    end
  end

  # ── Errores ────────────────────────────────────────────────────────────────

  @doc false
  def failure(conn, :not_configured) do
    conn
    |> put_status(:service_unavailable)
    |> json(%{
      errors: %{
        detail: "the instance has no Composio key configured",
        code: "not_configured"
      }
    })
  end

  def failure(conn, :not_allowed) do
    conn
    |> put_status(:forbidden)
    |> json(%{
      errors: %{
        detail: "this service is not exposed by the instance",
        code: "not_allowed"
      }
    })
  end

  def failure(conn, :no_identity) do
    conn
    |> put_status(:unauthorized)
    |> json(%{errors: %{detail: "no identity for this credential", code: "no_identity"}})
  end

  def failure(conn, {:composio, status, body}) do
    conn
    |> put_status(upstream_status(status))
    |> json(%{
      errors: %{
        detail: upstream_detail(body) || "the services provider refused the request",
        code: "provider_error"
      }
    })
  end

  def failure(conn, reason) do
    conn
    |> put_status(:internal_server_error)
    |> json(%{errors: %{detail: inspect(reason), code: "internal_error"}})
  end

  # El error del vendor no se reenvía tal cual (puede traer detalle del
  # proyecto); se resume, y un 5xx del vendor no se propaga como 5xx nuestro
  # sin decirlo.
  defp upstream_status(status) when status in [400, 401, 403, 404, 409, 422], do: status
  defp upstream_status(_status), do: :bad_gateway

  defp upstream_detail(body) when is_map(body) do
    body["message"] || get_in(body, ["error", "message"]) || get_in(body, ["errors", "detail"])
  end

  defp upstream_detail(_body), do: nil
end
