defmodule Dran.Inference.Client do
  @moduledoc """
  OpenAI-compatible inference client backed by `Req`.

  This is the low-level client. Higher-level helpers live in
  `Dran.Inference` and `Dran.Inference.MarkItDown`.
  """

  alias Dran.Inference.Config

  @type result(t) :: {:ok, t} | {:error, term()}

  @spec enabled?() :: boolean()
  def enabled?, do: Config.enabled?()

  @doc """
  List available models from the inference server.
  """
  @spec models() :: result(list(map()))
  def models do
    case Config.enabled?() do
      false ->
        {:error, :not_configured}

      true ->
        request(:get, "/models")
        |> map_response(fn body -> body["data"] || [] end)
    end
  end

  @doc """
  Generate embeddings for one or more inputs.
  """
  @spec embeddings(String.t(), String.t() | list(String.t())) :: result(list(list(float())))
  def embeddings(model, input) when is_binary(input), do: embeddings(model, [input])

  def embeddings(model, inputs) when is_list(inputs) do
    case Config.enabled?() do
      false ->
        {:error, :not_configured}

      true ->
        Dran.Inference.Queue.run(:embed, fn ->
          payload = %{
            "model" => model,
            "input" => inputs,
            "dimensions" => Config.embedding_dimensions()
          }

          request(:post, "/embeddings", json: payload)
          |> map_response(fn body ->
            body
            |> Map.get("data", [])
            |> Enum.sort_by(& &1["index"])
            |> Enum.map(& &1["embedding"])
          end)
        end)
    end
  end

  @doc """
  Rerank a list of documents against a query.
  """
  @spec rerank(String.t(), String.t(), list(String.t())) :: result(list(map()))
  def rerank(model, query, documents) do
    case Config.enabled?() do
      false ->
        {:error, :not_configured}

      true ->
        Dran.Inference.Queue.run(:rerank, fn ->
          payload = %{
            "model" => model,
            "query" => query,
            "documents" => documents
          }

          request(:post, "/rerank", json: payload)
          |> map_response(fn body -> Map.get(body, "results", []) end)
        end)
    end
  end

  @doc """
  Send a chat completion request.
  """
  @spec chat(map()) :: result(map())
  def chat(payload) when is_map(payload) do
    case Config.enabled?() do
      false ->
        {:error, :not_configured}

      true ->
        capability = chat_capability(payload["model"])

        Dran.Inference.Queue.run(capability, fn ->
          request(:post, "/chat/completions", json: payload)
          |> map_response(fn body ->
            body
            |> Map.get("choices", [])
            |> List.first(%{})
            |> Map.get("message", %{"content" => nil})
            |> Map.put("model", body["model"])
            |> Map.put("usage", body["usage"] || %{})
          end)
        end)
    end
  end

  def chat_capability(model) when is_binary(model) do
    cond do
      model == Config.markitdown_model() -> :markdown
      model == Config.vision_model() -> :vision
      true -> :chat
    end
  end

  def chat_capability(_), do: :chat

  @doc false
  def request(method, path, opts \\ []) do
    base = Config.base_url()
    key = Config.api_key()

    req_opts = [
      method: method,
      url: base <> path,
      headers: [{"authorization", "Bearer #{key}"}],
      receive_timeout: Config.timeout(),
      retry: :transient
    ]

    req_opts =
      case Config.config()[:req_plug] do
        nil -> req_opts
        plug -> Keyword.put(req_opts, :plug, plug)
      end

    req =
      Req.new(req_opts)
      |> Req.merge(opts)

    case Req.request(req) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp map_response({:ok, body}, fun) when is_function(fun, 1), do: {:ok, fun.(body)}
  defp map_response({:error, reason}, _fun), do: {:error, reason}
end
