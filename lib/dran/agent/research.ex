defmodule Dran.Agent.Research do
  @moduledoc """
  Research agent: searches/scrapes the web and creates pages in the brain.

  Enforces a structured research workflow with hard limits:

    * Maximum of `@max_sources` (10) distinct sources scraped.
    * No duplicate search queries or scrape URLs.
    * Tool calls that exceed limits return `{:error, :limit_reached}` so the
      LLM is nudged toward synthesis instead of looping.
  """

  @behaviour Dran.Agent.Engine.Behaviour

  alias Dran.{Brain, Firecrawl}

  @agent_type "research"
  @max_sources 10
  @max_search_queries 10

  defmodule State do
    @moduledoc false
    defstruct session: nil,
              module: nil,
              messages: [],
              step: 0,
              pages_created: 0,
              opts: [],
              search_queries: MapSet.new(),
              scraped_urls: MapSet.new(),
              sources: []
  end

  @doc """
  Start a research session for a topic.
  """
  @spec run(String.t(), Ecto.UUID.t(), keyword()) :: {:ok, Dran.Agent.Session.t()}
  def run(topic, context_id, opts \\ []) do
    Dran.Agent.Engine.run(__MODULE__, topic, context_id, opts)
  end

  @impl true
  def agent_type, do: @agent_type

  @doc "Maximum number of distinct sources the agent will scrape."
  def max_sources, do: @max_sources

  @doc "Maximum number of distinct web_search queries the agent will run."
  def max_search_queries, do: @max_search_queries

  @impl true
  def tools do
    [
      %{
        "type" => "function",
        "function" => %{
          "name" => "web_search",
          "description" =>
            "Search the web for pages about a query. Returns up to 5 results with url, title, and description. " <>
              "Use varied queries; duplicate queries are rejected.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "query" => %{
                "type" => "string",
                "description" => "Search query"
              }
            },
            "required" => ["query"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "web_scrape",
          "description" =>
            "Scrape a URL and return its markdown content. " <>
              "Only scrape URLs returned by web_search or already-cited sources. " <>
              "Duplicate URLs are rejected. Maximum #{@max_sources} sources total.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "url" => %{
                "type" => "string",
                "description" => "URL to scrape"
              }
            },
            "required" => ["url"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "create_page",
          "description" => "Create a new page in the brain.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "title" => %{"type" => "string", "description" => "Page title"},
              "slug" => %{"type" => "string", "description" => "URL-friendly slug"},
              "body" => %{
                "type" => "string",
                "description" => "Markdown body"
              },
              "page_type" => %{
                "type" => "string",
                "enum" => Brain.page_types(),
                "description" => "Page type"
              },
              "tags" => %{
                "type" => "array",
                "items" => %{"type" => "string"},
                "description" => "Tags"
              }
            },
            "required" => ["title", "body"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "search_pages",
          "description" => "Search existing pages in the brain.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "query" => %{
                "type" => "string",
                "description" => "Query"
              }
            },
            "required" => ["query"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "done",
          "description" => "Finish the research session with a summary.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "summary" => %{
                "type" => "string",
                "description" => "Short summary of what was researched and created"
              }
            },
            "required" => ["summary"]
          }
        }
      }
    ]
  end

  @impl true
  def system_prompt(opts \\ []) do
    lang = Keyword.get(opts, :lang, "es")
    lang_name = lang_name(lang)

    """
    You are a research agent for Dran. Research the topic thoroughly but efficiently.

    IMPORTANT - Language rules:
    - Web searches MUST always be in Spanish ("es") regardless of the output language.
      This ensures the best results from Spanish-speaking sources.
    - The pages you create (title, body, summary) MUST be written in #{lang_name} (#{lang}).
    - Tags should be in #{lang_name} unless they are proper nouns or established terms.

    Workflow:
    1. Use `search_pages` first to check what the brain already knows.
    2. Use `web_search` with focused, varied queries IN SPANISH to find authoritative sources.
       Do NOT repeat queries. Plan your queries in advance and diversify them.
    3. Use `web_scrape` to read the most promising URLs returned by web_search.
       Only scrape each URL once. You can scrape at most #{max_sources()} sources.
       Prioritize authoritative sites (Wikipedia, official docs, reputable publishers)
       over SEO spam, law firm landing pages, or parked domains.
    4. When you have enough material (3-#{max_sources()} sources), STOP searching and
       synthesize: use `create_page` to create 1-5 concise pages with citations IN #{String.upcase(lang_name)}.
       Pick a sensible page_type and cite sources in the body.
    5. Call `done` with a short summary.

    Hard limits enforced by the engine:
    - Duplicate web_search queries return an error.
    - Duplicate web_scrape URLs return an error.
    - Scraping past #{max_sources()} sources returns an error.
    - Once you have scraped several sources, you MUST move to synthesis.
    Do not loop. Do not retry the same query or URL. Progress forward.
    """
  end

  defp lang_name("es"), do: "Spanish"
  defp lang_name("en"), do: "English"
  defp lang_name("fr"), do: "French"
  defp lang_name("de"), do: "German"
  defp lang_name("pt"), do: "Portuguese"
  defp lang_name("it"), do: "Italian"
  defp lang_name("ja"), do: "Japanese"
  defp lang_name("zh"), do: "Chinese"
  defp lang_name(_), do: "Spanish"

  def build_messages(input, session, opts \\ []) do
    [
      %{"role" => "system", "content" => system_prompt(opts)},
      %{"role" => "user", "content" => "Research topic: #{input}\nSession: #{session.id}"}
    ]
  end

  @impl true
  def init_state(session, module, opts) do
    %State{
      session: session,
      module: module,
      messages: build_messages(session.input, session, opts),
      step: 0,
      pages_created: 0,
      opts: opts,
      search_queries: MapSet.new(),
      scraped_urls: MapSet.new(),
      sources: []
    }
  end

  @impl true
  def execute_tool("web_search", args, %State{} = state) do
    query = String.trim(args["query"] || "")

    cond do
      query == "" ->
        {{:error, "empty query"}, state}

      MapSet.member?(state.search_queries, query) ->
        previous = MapSet.to_list(state.search_queries) |> Enum.take(10)

        {{:error,
          "You already searched for '#{query}'. Do NOT repeat queries. " <>
            "Previous queries used: #{Enum.join(previous, ", ")}. " <>
            "Use a different angle or move to create_page / done."}, state}

      MapSet.size(state.search_queries) >= @max_search_queries ->
        {{:error,
          "You have used all #{@max_search_queries} search queries. " <>
            "You have #{length(state.sources)} sources scraped. " <>
            "STOP searching and call create_page to synthesize, then call done."}, state}

      true ->
        result = Firecrawl.search(query, limit: 5)
        new_state = %{state | search_queries: MapSet.put(state.search_queries, query)}
        {result, new_state}
    end
  end

  def execute_tool("web_scrape", args, %State{} = state) do
    url = String.trim(args["url"] || "")

    cond do
      url == "" ->
        {{:error, "empty url"}, state}

      MapSet.member?(state.scraped_urls, url) ->
        already = MapSet.to_list(state.scraped_urls)

        {{:error,
          "You already scraped #{url}. Do NOT scrape the same URL twice. " <>
            "URLs already scraped: #{Enum.join(already, ", ")}. " <>
            "Scrape a DIFFERENT URL from your search results, or move to create_page / done."},
         state}

      MapSet.size(state.scraped_urls) >= @max_sources ->
        {{:error,
          "You have scraped the maximum of #{@max_sources} sources. " <>
            "You have enough material. STOP scraping and call create_page to synthesize, then call done."},
         state}

      true ->
        case Firecrawl.scrape(url) do
          {:ok, page} ->
            source = %{
              url: page.url,
              title: page.title,
              markdown: String.slice(page.markdown || "", 0, 8_000)
            }

            new_state = %{
              state
              | scraped_urls: MapSet.put(state.scraped_urls, url),
                sources: state.sources ++ [source]
            }

            {{:ok, page}, new_state}

          error ->
            {error, state}
        end
    end
  end

  def execute_tool("create_page", args, %State{} = state) do
    page_attrs = %{
      context_id: state.session.context_id,
      title: args["title"],
      slug: args["slug"],
      body: args["body"],
      page_type: args["page_type"] || "concept",
      tags: args["tags"] || [],
      created_by: "research-agent",
      owner: "research-agent",
      meta: Map.merge(args["meta"] || %{}, %{"agent_session_id" => state.session.id})
    }

    case Brain.create_page(page_attrs) do
      {:ok, page} ->
        Phoenix.PubSub.broadcast(
          Dran.PubSub,
          "agents:#{state.session.id}",
          {:page_created, page}
        )

        {{:ok, %{slug: page.slug, id: page.id, title: page.title}},
         %{state | pages_created: state.pages_created + 1}}

      {:error, cs} ->
        {{:error, format_changeset_errors(cs)}, state}
    end
  end

  def execute_tool("search_pages", args, %State{} = state) do
    result =
      Brain.search(args["query"] || "", context_id: state.session.context_id, limit: 10)

    {result, state}
  end

  def execute_tool("done", _args, %State{} = state), do: {{:ok, :done}, state}

  def execute_tool(_tool, _args, %State{} = state), do: {{:error, :unknown_tool}, state}

  @impl true
  def summarize_result(result)

  def summarize_result({:ok, pages}) when is_list(pages) do
    %{status: "ok", count: length(pages), data: pages}
  end

  def summarize_result({:ok, %{slug: slug, title: title}}) do
    %{status: "ok", slug: slug, title: title}
  end

  def summarize_result({:ok, %{url: url, title: title, markdown: markdown}}) do
    %{status: "ok", url: url, title: title, markdown: String.slice(markdown || "", 0, 500)}
  end

  def summarize_result({:ok, :done}), do: %{status: "done"}

  def summarize_result({:error, reason}) when is_binary(reason) do
    %{status: "error", error: reason}
  end

  def summarize_result({:error, reason}), do: %{status: "error", error: inspect(reason)}

  @doc """
  Returns a human-readable summary of sources gathered so far,
  used by the engine when nudging the LLM toward synthesis.
  """
  @impl true
  def gathered_summary(%State{sources: sources}) when sources != [] do
    lines =
      sources
      |> Enum.with_index(1)
      |> Enum.map(fn {source, i} ->
        title = source[:title] || "Untitled"
        url = source[:url]
        snippet = String.slice(source[:markdown] || "", 0, 300)
        "#{i}. **#{title}** (#{url})\n   #{snippet}..."
      end)

    "Sources gathered (#{length(sources)}):\n\n" <> Enum.join(lines, "\n\n")
  end

  def gathered_summary(%State{sources: []}) do
    "No sources were successfully scraped, but you have search results. " <>
      "Create pages based on the search result descriptions you received."
  end

  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, val}, acc ->
        String.replace(acc, "%{#{key}}", to_string(val))
      end)
    end)
    |> Enum.map(fn {field, errors} -> "#{field}: #{Enum.join(errors, ", ")}" end)
    |> Enum.join("; ")
  end
end
