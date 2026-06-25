defmodule Dran.Agent.Research do
  @moduledoc """
  Research agent: searches/scrapes the web and creates pages in the brain.
  """

  @behaviour Dran.Agent.Engine.Behaviour

  alias Dran.{Brain, Firecrawl}

  @agent_type "research"

  @doc """
  Start a research session for a topic.
  """
  @spec run(String.t(), Ecto.UUID.t(), keyword()) :: {:ok, Dran.Agent.Session.t()}
  def run(topic, context_id, opts \\ []) do
    Dran.Agent.Engine.run(__MODULE__, topic, context_id, opts)
  end

  @impl true
  def agent_type, do: @agent_type

  @impl true
  def tools do
    [
      %{
        "type" => "function",
        "function" => %{
          "name" => "web_search",
          "description" => "Search the web for pages about a query.",
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
          "description" => "Scrape a URL and return its markdown content.",
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
  def system_prompt do
    """
    You are a research agent for Dran. Research the topic thoroughly.

    - Use `search_pages` first to check what the brain already knows.
    - Use `web_search` to find authoritative sources.
    - Use `web_scrape` to read important pages before citing them.
    - Use `create_page` to create 1-5 concise pages. Pick a sensible page_type (concept, entity, reference, note, etc.) and cite sources in the body.
    - Avoid duplicate pages already in the brain.
    - Call `done` when finished.
    """
  end

  @impl true
  def build_messages(input, session) do
    [
      %{"role" => "system", "content" => system_prompt()},
      %{"role" => "user", "content" => "Research topic: #{input}\nSession: #{session.id}"}
    ]
  end

  @impl true
  def execute_tool(tool, args, state)

  def execute_tool("web_search", args, state) do
    query = args["query"] || ""
    result = Firecrawl.search(query, limit: 5)
    {result, state}
  end

  @impl true
  def execute_tool("web_scrape", args, state) do
    url = args["url"] || ""
    result = Firecrawl.scrape(url)
    {result, state}
  end

  @impl true
  def execute_tool("create_page", args, state) do
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

  @impl true
  def execute_tool("search_pages", args, state) do
    result =
      Brain.search(args["query"] || "", context_id: state.session.context_id, limit: 10)

    {result, state}
  end

  @impl true
  def execute_tool("done", _args, state), do: {{:ok, :done}, state}

  @impl true
  def execute_tool(_tool, _args, state), do: {{:error, :unknown_tool}, state}

  @impl true
  def summarize_result(result)

  def summarize_result({:ok, pages}) when is_list(pages) do
    %{status: "ok", count: length(pages), data: pages}
  end

  def summarize_result({:ok, %{slug: slug, title: title}}) do
    %{status: "ok", slug: slug, title: title}
  end

  def summarize_result({:ok, :done}), do: %{status: "done"}

  def summarize_result({:error, reason}), do: %{status: "error", error: inspect(reason)}

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
