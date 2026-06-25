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
    chat: "Qwen3.6-35B-A3B"
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
  def embedding_model, do: get(:embedding_model)

  @spec rerank_model :: String.t()
  def rerank_model, do: get(:rerank_model)

  @spec markitdown_model :: String.t()
  def markitdown_model, do: get(:markitdown_model)

  @spec chat_model :: String.t()
  def chat_model, do: get(:chat_model)

  @spec asr_model :: String.t()
  def asr_model, do: get(:asr_model) || @default_models.chat

  @spec vision_model :: String.t()
  def vision_model, do: get(:vision_model) || @default_models.chat

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
          asr_model: System.get_env("DRAN_INFERENCE_ASR_MODEL", @default_models.chat),
          vision_model: System.get_env("DRAN_INFERENCE_VISION_MODEL", @default_models.chat),
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
