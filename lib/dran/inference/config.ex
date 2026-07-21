defmodule Dran.Inference.Config do
  @moduledoc """
  Runtime configuration for the inference API.

  Reads from environment variables at boot time. When `DRAN_INFERENCE_API_URL`
  is not set, inference features are disabled and the adapter returns
  `{:error, :not_configured}` for every call.
  """

  @default_models %{
    embedding: "Qwen3-Embedding",
    rerank: "Qwen3-Reranker",
    markitdown: "MarkItDown",
    chat: "Ornith-1.0-9B",
    vision: "Ornith-1.0-9B",
    asr: "Qwen3-ASR"
  }

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

  @spec embedding_model :: String.t()
  def embedding_model, do: model_or_env("embedding", fn -> get(:embedding_model) end)

  @spec rerank_model :: String.t()
  def rerank_model, do: model_or_env("rerank", fn -> get(:rerank_model) end)

  @spec markitdown_model :: String.t()
  def markitdown_model, do: model_or_env("markitdown", fn -> get(:markitdown_model) end)

  @spec chat_model :: String.t()
  def chat_model, do: model_or_env("chat", fn -> get(:chat_model) end)

  @spec asr_model :: String.t()
  def asr_model, do: model_or_env("asr", fn -> get(:asr_model) || @default_models.asr end)

  @spec vision_model :: String.t()
  def vision_model,
    do: model_or_env("vision", fn -> get(:vision_model) || @default_models.vision end)

  # Env-only model getters (bypass DB overrides). Used by the settings UI to
  # label which option is the env default and to compute the effective model
  # when no web override is set.
  @spec env_chat_model :: String.t() | nil
  def env_chat_model, do: get(:chat_model)

  @spec env_embedding_model :: String.t() | nil
  def env_embedding_model, do: get(:embedding_model)

  @spec env_rerank_model :: String.t() | nil
  def env_rerank_model, do: get(:rerank_model)

  @spec env_markitdown_model :: String.t() | nil
  def env_markitdown_model, do: get(:markitdown_model)

  @spec env_asr_model :: String.t()
  def env_asr_model, do: get(:asr_model) || @default_models.asr

  @spec env_vision_model :: String.t()
  def env_vision_model, do: get(:vision_model) || @default_models.vision

  # Reads a web-set model override from `Dran.Settings` (key "model_<purpose>")
  # before falling back to the env-provided default. If the repo is not yet
  # started (compile time, tests without sandbox, early boot), the DB lookup
  # would raise — we rescue and use the env default instead.
  defp model_or_env(purpose, env_fn) when is_binary(purpose) and is_function(env_fn, 0) do
    case read_setting("model_" <> purpose) do
      nil -> env_fn.()
      "" -> env_fn.()
      value -> value
    end
  end

  defp read_setting(key) do
    Dran.Settings.get(key)
  rescue
    _ -> nil
  end

  @spec use_rerank?() :: boolean()
  def use_rerank?, do: get(:use_rerank) || false

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
          embedding_model:
            System.get_env("DRAN_INFERENCE_EMBEDDING_MODEL", @default_models.embedding),
          rerank_model: System.get_env("DRAN_INFERENCE_RERANK_MODEL", @default_models.rerank),
          markitdown_model:
            System.get_env("DRAN_INFERENCE_MARKITDOWN_MODEL", @default_models.markitdown),
          chat_model: System.get_env("DRAN_INFERENCE_CHAT_MODEL", @default_models.chat),
          asr_model: System.get_env("DRAN_INFERENCE_ASR_MODEL", @default_models.asr),
          vision_model: System.get_env("DRAN_INFERENCE_VISION_MODEL", @default_models.vision),
          timeout: parse_timeout(System.get_env("DRAN_INFERENCE_TIMEOUT", "30000")),
          use_rerank: parse_boolean(System.get_env("DRAN_INFERENCE_USE_RERANK", "true")),
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

  defp parse_boolean(value) do
    value = String.downcase(to_string(value))
    value in ["true", "1", "yes", "on"]
  end
end
