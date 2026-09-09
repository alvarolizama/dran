defmodule Dran.Inference.Client do
  @moduledoc """
  OpenAI-compatible inference client backed by `Req`.

  This is the low-level client. Higher-level helpers live in
  `Dran.Inference`.
  """

  alias Dran.Inference.Config

  @type result(t) :: {:ok, t} | {:error, term()}

  @spec enabled?() :: boolean()
  def enabled?, do: Config.enabled?()

  @doc """
  Health-check the inference server by hitting `GET /models`.

  Returns `{:ok, %{latency_ms: n, models: count}}` on success, or
  `{:error, reason}` when the server is unreachable, misconfigured, or
  the API key is invalid. Used by the Settings UI "Probar conexión" button.
  """
  @spec ping() ::
          {:ok, %{latency_ms: non_neg_integer(), models: non_neg_integer()}} | {:error, term()}
  def ping do
    case Config.enabled?() do
      false ->
        {:error, :not_configured}

      true ->
        start = System.monotonic_time(:millisecond)

        case request(:get, "/models") do
          {:ok, body} ->
            latency = System.monotonic_time(:millisecond) - start
            count = length(body["data"] || [])
            {:ok, %{latency_ms: latency, models: count}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

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

  Speaks the Cohere/Jina shape (`POST /rerank` with flat `query`/`documents`,
  `results[]` at the top) by default. DashScope (QwenCloud) doesn't expose
  that path — its rerank only exists on the native
  `/api/v1/services/rerank/text-rerank/text-rerank` endpoint with a nested
  `input` payload and `output.results` response — so when the configured
  `base_url` points at dashscope we translate transparently.
  """
  @spec rerank(String.t(), String.t(), list(String.t())) :: result(list(map()))
  def rerank(model, query, documents) do
    case Config.enabled?() do
      false ->
        {:error, :not_configured}

      true ->
        Dran.Inference.Queue.run(:rerank, fn ->
          # The native endpoint lives at the host origin — NOT under the
          # compatible-mode prefix — so build an absolute URL from it.
          {path, payload, unwrap} =
            if dashscope?(Config.base_url()) do
              {
                origin(Config.base_url()) <>
                  "/api/v1/services/rerank/text-rerank/text-rerank",
                %{
                  "model" => model,
                  "input" => %{"query" => query, "documents" => documents},
                  "parameters" => %{"return_documents" => false}
                },
                fn body -> get_in(body, ["output", "results"]) || [] end
              }
            else
              {
                "/rerank",
                %{"model" => model, "query" => query, "documents" => documents},
                fn body -> Map.get(body, "results", []) end
              }
            end

          request(:post, path, json: payload)
          |> map_response(unwrap)
        end)
    end
  end

  # DashScope hosts don't serve /rerank (verified: compatible-mode returns
  # 404); rerank only exists on their native endpoint.
  defp dashscope?(nil), do: false

  defp dashscope?(base_url) do
    String.contains?(base_url, "dashscope")
  end

  # "https://host/prefix" → "https://host"
  defp origin(base_url) do
    case URI.new(base_url) do
      {:ok, %URI{scheme: scheme, host: host} = uri}
      when not is_nil(scheme) and not is_nil(host) ->
        %{uri | path: nil, query: nil, fragment: nil} |> URI.to_string()

      _ ->
        base_url
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

  @doc false
  def chat_capability(_model), do: :chat

  @doc false
  def request(method, path, opts \\ []) do
    base = Config.base_url()
    key = Config.api_key()

    # An absolute path (http…/…) bypasses the base_url — used by endpoints
    # that live at the host origin (e.g. DashScope's native rerank).
    url =
      if String.starts_with?(path, "http") do
        path
      else
        base <> path
      end

    req_opts = [
      method: method,
      url: url,
      headers: [{"authorization", "Bearer #{key}"}],
      receive_timeout: Config.timeout(),
      # Retry is handled by Agent.Engine.call_llm/2 — no double-retry.
      retry: false
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
