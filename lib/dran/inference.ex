defmodule Dran.Inference do
  @moduledoc """
  Public API for the OpenAI-compatible inference server.

  Works with four capabilities provided by the OpenAI-compatible inference server:

  - embeddings (`Qwen3-Embedding`)
  - reranking (`Qwen3-Reranker`)
  - document-to-markdown (`MarkItDown`)
  - chat helpers (`Ornith-1.0-9B`)

  When DRAN_INFERENCE_API_URL is not set, every function returns
  {:error, :not_configured} so the rest of the app can degrade gracefully.
  """

  alias Dran.Inference.{Client, Config}

  @doc """
  Returns `true` if inference has been configured via env vars.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Config.enabled?()

  @doc """
  List available models from the inference server.
  """
  @spec models() :: Client.result(list(map()))
  def models, do: Client.models()

  @doc """
  Generate an embedding for a single text using the configured model.
  """
  @spec embed(String.t()) :: Client.result(list(float()))
  def embed(text) when is_binary(text) do
    case Client.embeddings(Config.embedding_model(), [text]) do
      {:ok, [vector]} -> {:ok, vector}
      {:ok, []} -> {:error, :empty_embedding}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Rerank a list of document strings for the given query.
  """
  @spec rerank(String.t(), list(String.t())) :: Client.result(list(map()))
  def rerank(query, documents) when is_binary(query) and is_list(documents) do
    Client.rerank(Config.rerank_model(), query, documents)
  end

  @doc """
  Send a chat completion request using the configured chat-compatible model.
  """
  @spec chat(map()) :: Client.result(map())
  def chat(payload) when is_map(payload) do
    Client.chat(payload)
  end

  @doc """
  Returns the configured chat model name.
  """
  @spec chat_model() :: String.t()
  def chat_model, do: Config.chat_model()

  @doc """
  Check that the inference server is reachable and that the configured models
  are advertised by `/v1/models`.
  """
  @spec health_check() :: Client.result({list(String.t()), list(String.t())})
  def health_check do
    required = [
      Config.embedding_model(),
      Config.rerank_model(),
      Config.chat_model()
    ]

    with {:ok, models} <- models() do
      available = Enum.map(models, & &1["id"])
      present = Enum.filter(required, &(&1 in available))
      missing = required -- present
      {:ok, {present, missing}}
    end
  end
end
