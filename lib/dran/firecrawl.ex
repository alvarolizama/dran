defmodule Dran.Firecrawl do
  @moduledoc """
  Firecrawl HTTP client backed by `Req`.

  Provides web search and page scraping capabilities via the Firecrawl API.
  Disabled when `FIRECRAWL_API_KEY` is not set; calls in that state return
  `{:error, :not_configured}`.

  ## Configuration

  Configured in `config/runtime.exs`:

      config :dran, :firecrawl,
        api_key: System.get_env("FIRECRAWL_API_KEY"),
        base_url: "https://api.firecrawl.dev/v1"

  ## Usage

      {:ok, results} = Dran.Firecrawl.search("Elixir Phoenix framework")
      #=> {:ok, [%{url: "...", title: "...", description: "..."}, ...]}

      {:ok, page} = Dran.Firecrawl.scrape("https://hexdocs.pm/phoenix")
      #=> {:ok, %{url: "...", title: "...", markdown: "# Phoenix..."}}

  All public functions return `{:ok, result}` or `{:error, reason}` and never
  raise.
  """

  @type result(t) :: {:ok, t} | {:error, term()}

  @default_timeout 30_000

  @doc """
  Returns `true` when the Firecrawl API key is configured.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    not is_nil(api_key())
  end

  @doc """
  Search the web using Firecrawl's `/v1/search` endpoint.

  Returns `{:ok, [results]}` where each result is a map with
  `url`, `title`, and `description` string keys.

  ## Options

    * `:limit` — max number of results (default: `5`)

  ## Examples

      {:ok, results} = Dran.Firecrawl.search("Phoenix LiveView tutorial")
      {:ok, results} = Dran.Firecrawl.search("OTP supervision", limit: 10)
  """
  @spec search(String.t(), keyword()) :: result(list(map()))
  def search(query, opts \\ []) do
    with :ok <- check_enabled(),
         {:ok, body} <- post("/search", %{"query" => query, "limit" => opts[:limit] || 5}) do
      results =
        body
        |> Map.get("data", [])
        |> Enum.map(&to_search_result/1)

      {:ok, results}
    end
  end

  @doc """
  Scrape a single URL and return its content as markdown via Firecrawl's
  `/v1/scrape` endpoint.

  Returns `{:ok, %{url, title, markdown}}`.

  ## Examples

      {:ok, page} = Dran.Firecrawl.scrape("https://hexdocs.pm/phoenix")
      page.markdown #=> "# Phoenix Framework\\n..."
  """
  @spec scrape(String.t(), keyword()) :: result(map())
  def scrape(url, _opts \\ []) do
    with :ok <- check_enabled(),
         {:ok, body} <- post("/scrape", %{"url" => url, "formats" => ["markdown"]}) do
      data = Map.get(body, "data", %{})

      {:ok,
       %{
         url: Map.get(data, "url", url),
         title: Map.get(data, "title"),
         markdown: data |> Map.get("markdown") |> truncate_scrape()
       }}
    end
  end

  defp truncate_scrape(nil), do: nil
  defp truncate_scrape(text) when is_binary(text), do: String.slice(text, 0, 8_000)

  # --- Internals ---

  defp check_enabled do
    if enabled?(), do: :ok, else: {:error, :not_configured}
  end

  defp post(path, payload) do
    url = base_url() <> path

    headers = [
      {"authorization", "Bearer #{api_key()}"},
      {"content-type", "application/json"}
    ]

    try do
      response =
        Req.post!(url,
          json: payload,
          headers: headers,
          receive_timeout: @default_timeout
        )

      cond do
        response.status in 200..299 ->
          {:ok, response.body}

        true ->
          {:error, {:http_error, response.status, response.body}}
      end
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  defp to_search_result(item) do
    %{
      url: Map.get(item, "url"),
      title: Map.get(item, "title"),
      description: Map.get(item, "description")
    }
  end

  # --- Config helpers ---

  defp config, do: Application.get_env(:dran, :firecrawl) || []
  defp api_key, do: Keyword.get(config(), :api_key)
  defp base_url, do: Keyword.get(config(), :base_url) || "https://api.firecrawl.dev/v1"
end
