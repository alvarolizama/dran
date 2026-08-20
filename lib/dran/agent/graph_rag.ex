defmodule Dran.Agent.GraphRag do
  @moduledoc """
  GraphRAG agent: answers questions using GraphRAG patterns — local search
  (fan-out to neighbors), global search (community summaries), or drift
  search (hybrid).

  ## Search Modes

  - **Local** — specific questions about entities/topics. Seed via
    `hybrid_search`, fan-out via `expand_neighbors`, read via
    `get_page_content`, then `synthesize_answer`.
  - **Global** — holistic questions ("what are the main themes?").
    `list_communities` → `synthesize_answer`.
  - **Drift** — hybrid: local seed + community context → `synthesize_answer`.

  ## Limits

  - Max 10 `hybrid_search` calls per session
  - Max 5 `expand_neighbors` calls per session
  - Max 3 `get_community_context` calls per session
  - Max 1 answer page per session
  """

  @behaviour Dran.Agent.Engine.Behaviour

  alias Dran.Brain
  alias Dran.Graph.CommunitySummaries

  @agent_type "graph_rag"
  @max_searches 10
  @max_expands 5
  @max_community_context 3

  defmodule State do
    @moduledoc false
    defstruct session: nil,
              module: nil,
              messages: [],
              step: 0,
              pages_created: 0,
              opts: [],
              mode: nil,
              seeds: [],
              expanded: [],
              answer: nil,
              sources: [],
              searches_done: 0,
              expands_done: 0,
              community_contexts_done: 0
  end

  @doc "Start a graph_rag session."
  @spec run(String.t(), Ecto.UUID.t(), keyword()) :: {:ok, Dran.Agent.Session.t()}
  def run(input, workspace_id, opts \\ []) do
    Dran.Agent.Engine.run(__MODULE__, input, workspace_id, opts)
  end

  @impl true
  def agent_type, do: @agent_type

  @doc "Maximum number of search queries per session."
  def max_searches, do: @max_searches

  @doc "Maximum number of expand_neighbors calls per session."
  def max_expands, do: @max_expands

  @doc "Maximum number of get_community_context calls per session."
  def max_community_context, do: @max_community_context

  @impl true
  def tools do
    [
      %{
        "type" => "function",
        "function" => %{
          "name" => "hybrid_search",
          "description" =>
            "Search the knowledge base. Returns matching pages with slug, title, summary, and page_type. " <>
              "Maximum #{max_searches()} searches per session.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "query" => %{
                "type" => "string",
                "description" => "Search query"
              },
              "limit" => %{
                "type" => "integer",
                "description" => "Max results (default 10)",
                "default" => 10
              }
            },
            "required" => ["query"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "expand_neighbors",
          "description" =>
            "Fan-out from a seed page to find all relations (inbound + outbound). " <>
              "Returns neighboring pages with slug, title, relation_type, direction, and summary. " <>
              "Maximum #{max_expands()} expand calls per session.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "slug" => %{
                "type" => "string",
                "description" => "Slug of the seed page to expand from"
              },
              "depth" => %{
                "type" => "integer",
                "description" => "Expansion depth (1 or 2, default 1)",
                "default" => 1
              }
            },
            "required" => ["slug"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "get_page_content",
          "description" => "Read a page's full body, title, page_type, and meta.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "slug" => %{
                "type" => "string",
                "description" => "Slug of the page to read"
              }
            },
            "required" => ["slug"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "get_community_context",
          "description" =>
            "Get the community summary for a page's detected community. " <>
              "Returns community_id, summary, page_count, and top_pages. " <>
              "Maximum #{max_community_context()} calls per session.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "slug" => %{
                "type" => "string",
                "description" => "Slug of the page to get community context for"
              }
            },
            "required" => ["slug"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "list_communities",
          "description" =>
            "List all community summaries for this context. " <>
              "Returns a list of %{community_id, summary, page_count, top_pages}.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{},
            "required" => []
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "synthesize_answer",
          "description" =>
            "Generate the final answer. Records the answer, mode, and sources for later persistence.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "answer" => %{
                "type" => "string",
                "description" => "The synthesized answer text"
              },
              "mode" => %{
                "type" => "string",
                "enum" => ["local", "global", "drift"],
                "description" => "The search mode used"
              },
              "sources" => %{
                "type" => "array",
                "items" => %{"type" => "string"},
                "description" => "List of page slugs cited as sources"
              }
            },
            "required" => ["answer", "mode"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "create_answer_page",
          "description" =>
            "Persist the answer as a note page. " <>
              "Creates a page with page_type: note (kind=answer) and adds source relations. " <>
              "Limited to 1 per session.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "title" => %{
                "type" => "string",
                "description" => "Title for the answer page"
              },
              "body" => %{
                "type" => "string",
                "description" => "Markdown body of the answer"
              }
            },
            "required" => ["title", "body"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "done",
          "description" => "Finish the graph_rag session with a summary.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "summary" => %{
                "type" => "string",
                "description" => "Short summary of the session"
              }
            },
            "required" => ["summary"]
          }
        }
      }
    ]
  end

  @impl true
  def system_prompt(_opts \\ []) do
    """
    You are a GraphRAG agent for a personal knowledge base. You answer questions by combining graph-based retrieval with LLM synthesis.

    You have three search modes:

    1. LOCAL SEARCH — for specific questions about entities/topics. Use hybrid_search to find seed pages, expand_neighbors to fan out, get_page_content to read relevant pages, then synthesize_answer.

    2. GLOBAL SEARCH — for holistic questions about the entire knowledge base ("what are the main themes?", "what do I know about X broadly?"). Use list_communities to get community summaries, then synthesize_answer.

    3. DRIFT SEARCH — hybrid: start with local search to find relevant pages, then get_community_context to understand the broader context, then synthesize_answer with both levels.

    Choose the mode based on the question:
    - Specific entity/topic → LOCAL
    - Broad/holistic/overview → GLOBAL
    - Specific but needs context → DRIFT

    Rules:
    - Always cite sources (page slugs) in your answer
    - Create exactly one answer page (note with kind=answer) with the final answer
    - Be concise but thorough
    - If you can't find relevant information, say so honestly
    """
  end

  def build_messages(input, session, _opts \\ []) do
    [
      %{"role" => "system", "content" => system_prompt()},
      %{
        "role" => "user",
        "content" =>
          "GraphRAG query: #{input}\nContext: #{session.workspace_id}\nSession: #{session.id}"
      }
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
      mode: nil,
      seeds: [],
      expanded: [],
      answer: nil,
      sources: []
    }
  end

  # ── Tool execution ────────────────────────────────────────────────────────

  @impl true
  def execute_tool("hybrid_search", args, %State{} = state) do
    cond do
      state.searches_done >= @max_searches ->
        {{:error, "search limit reached (#{@max_searches} per session)"}, state}

      true ->
        query = args["query"] || ""
        limit = args["limit"] || 10

        if String.trim(query) == "" do
          {{:error, "query is required"}, state}
        else
          case Brain.search(query, workspace_id: state.session.workspace_id, limit: limit) do
            {:ok, results} ->
              seeds =
                Enum.map(results, fn r ->
                  %{
                    slug: r.slug,
                    title: r.title,
                    summary: Map.get(r, :summary, r.excerpt),
                    page_type: r.page_type
                  }
                end)

              {{:ok, seeds},
               %{state | seeds: state.seeds ++ seeds, searches_done: state.searches_done + 1}}

            {:error, reason} ->
              {{:error, "search failed: #{inspect(reason)}"}, state}
          end
        end
    end
  end

  def execute_tool("expand_neighbors", args, %State{} = state) do
    cond do
      state.expands_done >= @max_expands ->
        {{:error, "expand limit reached (#{@max_expands} per session)"}, state}

      true ->
        slug = String.trim(args["slug"] || "")
        depth = min(args["depth"] || 1, 2)

        if slug == "" do
          {{:error, "slug is required"}, state}
        else
          workspace_id = state.session.workspace_id

          case Brain.get_page_by_slug(slug, workspace_id) do
            nil ->
              {{:error, "page '#{slug}' not found"}, state}

            page ->
              neighbors = collect_neighbors(page.id, workspace_id, depth, 0, %{})

              expanded =
                Enum.map(neighbors, fn %{page: p, direction: dir, relation_type: rt} ->
                  %{
                    slug: p.slug,
                    title: p.title,
                    relation_type: rt,
                    direction: dir,
                    summary: p.summary || ""
                  }
                end)

              {{:ok, expanded},
               %{
                 state
                 | expanded: state.expanded ++ expanded,
                   expands_done: state.expands_done + 1
               }}
          end
        end
    end
  end

  def execute_tool("get_page_content", args, %State{} = state) do
    slug = String.trim(args["slug"] || "")

    if slug == "" do
      {{:error, "slug is required"}, state}
    else
      workspace_id = state.session.workspace_id

      case Brain.get_page_by_slug(slug, workspace_id) do
        nil ->
          {{:error, "page '#{slug}' not found"}, state}

        page ->
          {{:ok,
            %{
              slug: page.slug,
              title: page.title,
              body: page.body,
              page_type: page.page_type,
              meta: page.meta
            }}, state}
      end
    end
  end

  def execute_tool("get_community_context", args, %State{} = state) do
    cond do
      state.community_contexts_done >= @max_community_context ->
        {{:error, "community_context limit reached (#{@max_community_context} per session)"},
         state}

      true ->
        slug = String.trim(args["slug"] || "")

        if slug == "" do
          {{:error, "slug is required"}, state}
        else
          workspace_id = state.session.workspace_id

          case Brain.get_page_by_slug(slug, workspace_id) do
            nil ->
              {{:error, "page '#{slug}' not found"}, state}

            page ->
              community_id = parse_community_id(page.meta["community_id"])

              result =
                if Code.ensure_loaded?(Dran.Graph.CommunitySummaries) do
                  case CommunitySummaries.get_summary(workspace_id, community_id) do
                    {:ok, cs} ->
                      {:ok,
                       %{
                         community_id: cs.community_id,
                         summary: cs.summary,
                         page_count: cs.page_count,
                         top_pages: cs.top_pages
                       }}

                    {:error, :not_found} ->
                      {:ok,
                       %{
                         community_id: community_id,
                         summary: "No summary available for this community yet.",
                         page_count: 0,
                         top_pages: []
                       }}
                  end
                else
                  {:ok,
                   %{
                     community_id: community_id,
                     summary: "Community summaries not yet generated.",
                     page_count: 0,
                     top_pages: []
                   }}
                end

              {result, %{state | community_contexts_done: state.community_contexts_done + 1}}
          end
        end
    end
  end

  def execute_tool("list_communities", _args, %State{} = state) do
    workspace_id = state.session.workspace_id

    result =
      if Code.ensure_loaded?(Dran.Graph.CommunitySummaries) do
        summaries = CommunitySummaries.list_summaries(workspace_id)

        {:ok,
         Enum.map(summaries, fn cs ->
           %{
             community_id: cs.community_id,
             summary: cs.summary,
             page_count: cs.page_count,
             top_pages: cs.top_pages
           }
         end)}
      else
        {:ok, []}
      end

    {result, state}
  end

  def execute_tool("synthesize_answer", args, %State{} = state) do
    answer = args["answer"] || ""
    mode = args["mode"] || "local"
    sources = args["sources"] || []

    if String.trim(answer) == "" do
      {{:error, "answer is required"}, state}
    else
      {{:ok, "Answer recorded. Use create_answer_page to persist."},
       %{state | answer: answer, mode: mode, sources: sources}}
    end
  end

  def execute_tool("create_answer_page", args, %State{} = state) do
    cond do
      state.pages_created >= 1 ->
        {{:error, "answer page limit reached (1 per session)"}, state}

      is_nil(state.answer) ->
        {{:error, "call synthesize_answer first to record the answer"}, state}

      true ->
        title = args["title"] || ""
        body = args["body"] || ""

        if String.trim(title) == "" or String.trim(body) == "" do
          {{:error, "title and body are required"}, state}
        else
          workspace_id = state.session.workspace_id
          sources = state.sources || []

          page_attrs = %{
            workspace_id: workspace_id,
            title: title,
            body: body,
            page_type: "note",
            created_by: "graph_rager",
            owner: "graph_rager",
            meta: %{
              "mode" => state.mode,
              "kind" => "answer",
              "agent_session_id" => state.session.id,
              "sources" => sources
            }
          }

          case Brain.create_page(page_attrs) do
            {:ok, page} ->
              create_source_relations(page, sources, workspace_id)

              Phoenix.PubSub.broadcast(
                Dran.PubSub,
                "agents:#{state.session.id}",
                {:page_created, page}
              )

              url = "/notes/#{page.slug}"

              {{:ok, %{slug: page.slug, url: url}},
               %{state | pages_created: state.pages_created + 1}}

            {:error, cs} ->
              {{:error, format_changeset_errors(cs)}, state}
          end
        end
    end
  end

  def execute_tool("done", _args, %State{} = state), do: {{:ok, :done}, state}

  def execute_tool(_tool, _args, %State{} = state), do: {{:error, :unknown_tool}, state}

  # ── Behaviour callbacks (optional) ─────────────────────────────────────────

  @impl true
  def summarize_result({:ok, :done}), do: %{status: "done"}

  def summarize_result({:ok, %{slug: slug, url: url}}) do
    %{status: "ok", slug: slug, url: url}
  end

  def summarize_result({:ok, %{slug: slug, title: title}}) do
    %{status: "ok", slug: slug, title: title}
  end

  def summarize_result({:ok, seeds}) when is_list(seeds) do
    %{status: "ok", count: length(seeds), data: seeds}
  end

  def summarize_result({:ok, page}) when is_map(page) do
    %{status: "ok", data: page}
  end

  def summarize_result({:ok, msg}) when is_binary(msg) do
    %{status: "ok", message: msg}
  end

  def summarize_result({:error, reason}) when is_binary(reason) do
    %{status: "error", error: reason}
  end

  def summarize_result({:error, reason}), do: %{status: "error", error: inspect(reason)}

  @impl true
  def gathered_summary(%State{seeds: seeds, expanded: expanded, answer: answer, mode: mode}) do
    parts = []
    parts = if mode, do: ["Mode: #{mode}" | parts], else: parts
    parts = if seeds != [], do: ["#{length(seeds)} seed page(s) found" | parts], else: parts

    parts =
      if expanded != [],
        do: ["#{length(expanded)} neighbor(s) expanded" | parts],
        else: parts

    parts = if answer, do: ["Answer synthesized" | parts], else: parts

    "GraphRAG progress: #{Enum.join(Enum.reverse(parts), "; ")}. " <>
      "Use synthesize_answer and create_answer_page to finalize."
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  @spec collect_neighbors(binary(), binary(), integer(), integer(), map()) :: list()
  defp collect_neighbors(page_id, workspace_id, max_depth, current_depth, visited) do
    if current_depth >= max_depth or Map.has_key?(visited, page_id) do
      []
    else
      visited = Map.put(visited, page_id, true)
      %{outbound: outbound, inbound: inbound} = Brain.list_relations_for_page(page_id)

      neighbors =
        Enum.map(outbound, fn r ->
          %{
            page: r.target,
            direction: "outbound",
            relation_type: r.relation_type
          }
        end) ++
          Enum.map(inbound, fn r ->
            %{
              page: r.source,
              direction: "inbound",
              relation_type: r.relation_type
            }
          end)

      if current_depth + 1 < max_depth do
        deeper =
          Enum.flat_map(neighbors, fn %{page: p} ->
            collect_neighbors(p.id, workspace_id, max_depth, current_depth + 1, visited)
          end)

        neighbors ++ deeper
      else
        neighbors
      end
    end
  end

  @spec create_source_relations(map(), [String.t()], binary()) :: :ok
  defp create_source_relations(answer_page, source_slugs, workspace_id) do
    Enum.each(source_slugs, fn slug ->
      case Brain.get_page_by_slug(slug, workspace_id) do
        nil ->
          :ok

        source_page ->
          Brain.create_relation(%{
            source_id: answer_page.id,
            target_id: source_page.id,
            relation_type: "related",
            meta: %{"created_by" => "graph_rager", "purpose" => "source_citation"}
          })
      end
    end)

    :ok
  end

  @spec parse_community_id(term()) :: integer() | nil
  defp parse_community_id(nil), do: nil
  defp parse_community_id(v) when is_integer(v), do: v
  defp parse_community_id(v) when is_float(v), do: round(v)

  defp parse_community_id(v) when is_binary(v) do
    case Integer.parse(v) do
      {i, _rest} -> i
      :error -> nil
    end
  end

  defp parse_community_id(_), do: nil

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
