defmodule Dran.Composio.Config do
  @moduledoc """
  Runtime configuration for the Composio integration (v3.1 REST).

  Reads from environment variables at boot time, exactly like
  `Dran.Inference.Config`: when `DRAN_COMPOSIO_API_KEY` is not set the whole
  services surface is disabled and every call answers `{:error,
  :not_configured}` — the feature cannot half-exist.

  The key is **instance state**, not a user credential: one scoped project key
  for the instance, living server-side only (the UI shows its STATE, never its
  value). Users connect their own accounts; the catalog and the bill are the
  instance's.

  `req_plug` is the test seam (see `Dran.Inference.Config`): tests inject
  `{Req.Test, Dran.Composio}` so no request leaves the process.
  """

  @default_base_url "https://backend.composio.dev"
  # Presupuesto de una LECTURA al vendor. Los defaults del ladder están
  # documentados en el README («Presupuestos de servicios: el ladder») y el
  # invariante es uno: **el presupuesto del servidor va por DEBAJO del cap del
  # cliente** (el plugin de Hermes: 15 s en `services_timeout_s`). Con el
  # servidor cortando primero, un proveedor lento sale como error TIPADO de dran
  # — con capa y contexto — en vez de un socket timeout mudo del lado del
  # cliente, que sólo puede decir «dran unavailable».
  @default_timeout 12_000
  # Presupuesto de una EJECUCIÓN (la acción real contra el proveedor: un envío,
  # una subida, una creación). También por debajo del cap del cliente
  # (`services_run_timeout_s`, 45 s), y más generoso porque acá el trabajo real
  # ocurre del otro lado.
  @default_execute_timeout 25_000

  @spec config() :: keyword() | nil
  def config do
    case Application.get_env(:dran, :composio) do
      nil -> nil
      cfg -> Enum.reject(cfg, fn {_k, v} -> is_nil(v) end)
    end
  end

  @doc """
  The integration is configured when the instance key is present. The base URL
  always resolves (vendor default), so the KEY is what turns the surface on.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: not is_nil(api_key())

  @spec base_url() :: String.t()
  def base_url, do: get(:base_url) || @default_base_url

  @spec api_key() :: String.t() | nil
  def api_key, do: get(:api_key)

  @spec timeout() :: pos_integer()
  def timeout, do: get(:timeout) || @default_timeout

  @doc """
  El presupuesto de una EJECUCIÓN contra el vendor (ms).

  Separado del de lectura porque la consecuencia es otra: una lectura lenta se
  reintenta sin costo, un `execute` que se pasó del cap puede haber aterrizado
  igual (el mutador corrió y sólo se perdió la respuesta).
  """
  @spec execute_timeout() :: pos_integer()
  def execute_timeout, do: get(:execute_timeout) || @default_execute_timeout

  @doc false
  @spec req_plug() :: module() | {module(), term()} | nil
  def req_plug, do: get(:req_plug)

  defp get(key) do
    case config() do
      nil -> nil
      cfg -> Keyword.get(cfg, key)
    end
  end

  @doc false
  @spec load_from_env() :: keyword() | nil
  def load_from_env do
    case System.get_env("DRAN_COMPOSIO_API_KEY") do
      nil ->
        nil

      "" ->
        nil

      key ->
        [
          base_url:
            ensure_no_trailing_slash(System.get_env("DRAN_COMPOSIO_BASE_URL", @default_base_url)),
          api_key: key,
          timeout: parse_timeout(System.get_env("DRAN_COMPOSIO_TIMEOUT", "12000")),
          execute_timeout:
            parse_timeout(
              System.get_env("DRAN_COMPOSIO_EXECUTE_TIMEOUT", "25000"),
              @default_execute_timeout
            )
        ]
    end
  end

  defp ensure_no_trailing_slash(url) do
    if String.ends_with?(url, "/") do
      String.slice(url, 0..-2//1)
    else
      url
    end
  end

  defp parse_timeout(value, default \\ @default_timeout) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> n
      _ -> default
    end
  end
end
