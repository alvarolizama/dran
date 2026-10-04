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
  @default_timeout 30_000

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
          timeout: parse_timeout(System.get_env("DRAN_COMPOSIO_TIMEOUT", "30000"))
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

  defp parse_timeout(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> n
      _ -> @default_timeout
    end
  end
end
