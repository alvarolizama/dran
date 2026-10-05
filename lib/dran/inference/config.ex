defmodule Dran.Inference.Config do
  @moduledoc """
  Runtime configuration for the inference API.

  Reads from environment variables at boot time. When `DRAN_INFERENCE_API_URL`
  is not set, inference features are disabled and the adapter returns
  `{:error, :not_configured}` for every call.
  """

  @spec config() :: keyword() | nil
  def config do
    case Application.get_env(:dran, :inference) do
      nil -> nil
      cfg -> Enum.reject(cfg, fn {_k, v} -> is_nil(v) end)
    end
  end

  @spec enabled?() :: boolean()
  def enabled? do
    not is_nil(base_url())
  end

  @spec base_url :: String.t() | nil
  def base_url, do: get(:base_url)

  @spec api_key :: String.t() | nil
  def api_key, do: get(:api_key)

  # The model names are runtime settings (Admin → Models writes
  # `model_chat` / `model_embedding` into the settings table). The old
  # `:"#{key}_model"` config-key fallback read a keyword nobody ever set
  # (`load_from_env` emits no such key) — dead branch, and the atom it built
  # from interpolation is what sobelow flagged (DOS.BinToAtom).
  @spec embedding_model :: String.t() | nil
  def embedding_model, do: Dran.Settings.get("model_embedding")

  @spec chat_model :: String.t() | nil
  def chat_model, do: Dran.Settings.get("model_chat")

  @spec embedding_dimensions :: pos_integer()
  def embedding_dimensions, do: get(:embedding_dimensions) || 1024

  @spec embedding_body_limit :: pos_integer()
  def embedding_body_limit, do: get(:embedding_body_limit) || 10_000

  @spec timeout :: pos_integer()
  def timeout, do: get(:timeout) || 30_000

  defp get(key) do
    case config() do
      nil -> nil
      cfg -> Keyword.get(cfg, key)
    end
  end

  @doc false
  @spec load_from_env() :: keyword() | nil
  def load_from_env do
    case System.get_env("DRAN_INFERENCE_API_URL") do
      nil ->
        nil

      "" ->
        nil

      url ->
        [
          base_url: ensure_no_trailing_slash(url),
          api_key: System.get_env("DRAN_INFERENCE_API_KEY"),
          timeout: parse_timeout(System.get_env("DRAN_INFERENCE_TIMEOUT", "30000")),
          embedding_dimensions: 1024,
          embedding_body_limit:
            parse_int(System.get_env("DRAN_EMBEDDING_BODY_LIMIT", "10000"), 10000)
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
      _ -> 30_000
    end
  end

  defp parse_int(value, default) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> n
      _ -> default
    end
  end
end
