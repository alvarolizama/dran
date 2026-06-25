defmodule Dran.Agent.Search do
  @moduledoc """
  Search agent: answers a query by orchestrating semantic, full-text, and web
  search, producing a report of top results and semantic relations.

  It does **not** create pages — it only searches and reports findings.
  """

  @behaviour Dran.Agent.Engine.Behaviour

  alias Dran.{Brain, Firecrawl}

  @agent_type "search"

  @doc """
  Start a search session for a query.
  """
  @spec run(String.t(), Ecto.UUID.t(), keyword()) :: {:ok, Dran.Agent.Session.t()}
  def run(query, context_id, opts \\ []) do
    Dran.Agent.Engine.run(__MODULE__, query, context_id, opts)
  end

  @impl true
  def agent_type, do: @agent_type

  @impl true
  def tools do
    [
      %{
        "type" => "function",
        "function" => %{
          "name" => "semantic_search",
          "description" => "Semantic search across pages in the brain.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "query" => %{"type" => "string", "description" => "Query"}
            },
            "required" => ["query"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "full_text_search",
          "description" => "Full-text search across pages in the brain.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "query" => %{"type" => "string", "description" => "Query"}
            },
            "required" => ["query"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "web_search",
          "description" => "Search the web if Firecrawl is enabled.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "query" => %{"type" => "string", "description" => "Query"}
            },
            "required" => ["query"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "done",
          "description" => "Finish the search session with a summary report.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "summary" => %{
                "type" => "string",
                "description" => "Concise answer with top results and semantic relations"
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
    You are a search agent for Dran. Answer the user's query by searching the brain.
    You do NOT create pages — only produce a final report.

    - Use `semantic_search` for conceptual/natural-language queries.
    - Use `full_text_search` for exact phrases or keywords.
    - Use `web_search` only when the brain lacks the answer and Firecrawl is available.
    - Synthesize a concise answer with the top results and key semantic relations.
    - Always end by calling `done` with the summary.
    """
  end

  @impl true
  def build_messages(input, session) do
    [
      %{"role" => "system", "content" => system_prompt()},
      %{"role" => "user", "content" => "Query: #{input}\nSession: #{session.id}"}
    ]
  end

  @impl true
  def execute_tool(tool, args, state)

  @impl true
  def execute_tool("semantic_search", args, state) do
    result =
      Brain.semantic_search(
        args["query"] || "",
        context_id: state.session.context_id,
        limit: 10
      )

    {result, state}
  end

  @impl true
  def execute_tool("full_text_search", args, state) do
    result =
      Brain.search(
        args["query"] || "",
        context_id: state.session.context_id,
        strategy: :fts,
        limit: 10
      )

    {result, state}
  end

  @impl true
  def execute_tool("web_search", args, state) do
    result = Firecrawl.search(args["query"] || "", limit: 5)
    {result, state}
  end

  @impl true
  def execute_tool("done", _args, state), do: {{:ok, :done}, state}

  @impl true
  def execute_tool(_tool, _args, state), do: {{:error, :unknown_tool}, state}

  @impl true
  def summarize_result(result)

  def summarize_result({:ok, results}) when is_list(results),
    do: %{status: "ok", count: length(results), data: results}

  def summarize_result({:ok, :done}), do: %{status: "done"}
  def summarize_result({:error, reason}), do: %{status: "error", error: inspect(reason)}
  def summarize_result(other), do: %{status: "ok", data: other}
end
