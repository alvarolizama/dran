defmodule Dran.MCP do
  @moduledoc """
  MCP (Model Context Protocol) server for Dran — Streamable HTTP transport.

  Served from Phoenix at `/mcp`. Supports POST, GET, and DELETE per
  MCP spec 2025-03-26 Streamable HTTP transport.

  ## Endpoints
  - `POST /mcp` — send JSON-RPC request → JSON or SSE response
  - `GET /mcp` — open SSE stream for server-initiated messages
  - `DELETE /mcp` — terminate session

  ## Tools
  - `search` — FTS search across pages
  - `semantic_search` — vector search across pages (needs inference API)
  - `create_page` — create a new page
  - `update_page` — update an existing page
  - `get_page` — get a page by slug (returns markdown)
  - `delete_page` — delete a page by slug (cascades to relations + versions)
  - `create_todo` — create a todo item
  - `update_todo` — update a todo's kanban status, priority, or due date (merges meta)
  - `create_relation` — create a typed relation between two pages
  - `delete_relation` — delete a relation between two pages (by slug pair + optional type)
  - `get_links` — get inbound + outbound relations for a page
  - `list_pages` — list pages with filters (type, tag, status, limit)
  - `stats` — aggregate statistics for a context (page counts, todos by status, orphans)
  - `lint` — run lint report for a context
  - `rename_slug` — rename a page's slug and relink all wikilinks/embeds across the context
  - `ingest_url` — save a URL or download a file as a reference page

  ## Resources
  - `page://{context}/{slug}` — page content as markdown
  - `goal://{context}/{slug}` — goal detail with todos and plans
  - `wiki://{context}/index` — wiki index (all slugs + titles)

  ## Prompts
  - `research_topic` — scaffold a research page
  - `brainstorm` — generate ideas around a topic
  - `goal_review` — review a goal's status
  """

  alias Dran.Brain

  @protocol_version "2025-03-26"

  @tools [
    %{
      "name" => "search",
      "description" =>
        "Unified search across pages in a context. Automatically picks the best available strategy: full-text, fuzzy, semantic or hybrid. Requires the inference API for semantic/hybrid strategies; degrades gracefully to full-text if inference is unavailable.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "query" => %{"type" => "string", "description" => "Search query (natural language)"},
          "context" => %{"type" => "string", "description" => "Context slug (e.g. 'personal')"},
          "type" => %{
            "type" => "string",
            "description" =>
              "Filter by page type: note, concept, entity, reference, goal, plan, todo, artifact, comparison (optional)"
          },
          "strategy" => %{
            "type" => "string",
            "enum" => ["auto", "fts", "fuzzy", "semantic", "hybrid"],
            "description" =>
              "Search strategy. 'auto' picks the best one. 'semantic' and 'hybrid' require inference API."
          }
        },
        "required" => ["query", "context"]
      }
    },
    %{
      "name" => "semantic_search",
      "description" =>
        "Deprecated alias for search with strategy='semantic'. Use 'search' instead.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "query" => %{"type" => "string", "description" => "Search query (natural language)"},
          "context" => %{"type" => "string", "description" => "Context slug (e.g. 'personal')"},
          "type" => %{
            "type" => "string",
            "description" =>
              "Filter by page type: note, concept, entity, reference, goal, plan, todo, artifact, comparison (optional)"
          },
          "hybrid" => %{
            "type" => "boolean",
            "description" => "Use hybrid strategy (default: false, i.e. semantic)"
          }
        },
        "required" => ["query", "context"]
      }
    },
    %{
      "name" => "create_page",
      "description" => """
      Create a new page in the second brain. Each page has a type that determines its purpose and metadata.

      Page types and their subtypes (use 'kind' in meta):
      - note: thought, journal, idea, meeting, question, quote
      - concept: technique, pattern, discipline, theory
      - entity: person, company, product, tool, place, event
      - reference: article, paper, video, podcast, book
      - artifact: document, code, design, deliverable, file
      - goal: has health (green/yellow/red), target_date
      - plan: has horizon (weekly/monthly/quarterly/yearly), status
      - todo: has kanban_status (backlog/this_week/today/in_progress/done/cancelled), priority (low/medium/high/urgent)
      - comparison: has entities, criteria, verdict

      Use [[slug]] in body to wikilink to other pages. Use ![[slug]] to embed artifacts.
      """,
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "context" => %{"type" => "string", "description" => "Context slug"},
          "title" => %{"type" => "string", "description" => "Page title"},
          "slug" => %{
            "type" => "string",
            "description" => "URL-friendly slug (kebab-case, unique per context)"
          },
          "body" => %{
            "type" => "string",
            "description" =>
              "Page content in Markdown. Use [[slug]] for wikilinks, ![[slug]] for embeds."
          },
          "page_type" => %{
            "type" => "string",
            "description" =>
              "Page type: note, concept, entity, reference, goal, plan, todo, artifact, comparison",
            "enum" => [
              "note",
              "concept",
              "entity",
              "reference",
              "goal",
              "plan",
              "todo",
              "artifact",
              "comparison"
            ]
          },
          "tags" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Tags (kebab-case)"
          },
          "meta" => %{
            "type" => "object",
            "description" =>
              "Type-specific metadata. Key fields by type: note→{kind, date}, todo→{kanban_status, priority, goal_slug, due_date}, goal→{health, target_date, start_date, team}, plan→{horizon, status}, reference→{source_url, kind}, entity→{kind, aliases, external_url}, concept→{kind, domain, parent_concept}, artifact→{kind, filename, mime_type, storage_path}, comparison→{entities, criteria, verdict}."
          },
          "summary" => %{"type" => "string", "description" => "One-line summary (optional)"},
          "owner" => %{"type" => "string", "description" => "Owner identity (defaults to system)"},
          "created_by" => %{
            "type" => "string",
            "description" => "Who created this page (defaults to system)"
          }
        },
        "required" => ["context", "title", "slug", "page_type"]
      }
    },
    %{
      "name" => "update_page",
      "description" =>
        "Update an existing page by slug. Can update title, body, tags, or meta. Version auto-increments on body change. Wikilinks in body are auto-resolved into relations.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "context" => %{"type" => "string", "description" => "Context slug"},
          "slug" => %{"type" => "string", "description" => "Page slug to update"},
          "title" => %{"type" => "string", "description" => "New title (optional)"},
          "body" => %{
            "type" => "string",
            "description" => "New markdown body (optional). Use [[slug]] for wikilinks."
          },
          "tags" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "New tags (optional)"
          },
          "meta" => %{"type" => "object", "description" => "Updated metadata (optional)"},
          "updated_by" => %{
            "type" => "string",
            "description" => "Who is updating (defaults to system)"
          }
        },
        "required" => ["context", "slug"]
      }
    },
    %{
      "name" => "get_page",
      "description" =>
        "Get a page by slug. Returns full markdown content with metadata. Use this to read a single page's content.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "context" => %{"type" => "string", "description" => "Context slug"},
          "slug" => %{"type" => "string", "description" => "Page slug"}
        },
        "required" => ["context", "slug"]
      }
    },
    %{
      "name" => "create_todo",
      "description" =>
        "Create a todo item linked to a goal. Todos have kanban_status (backlog/this_week/today/in_progress/done/cancelled) and priority (low/medium/high/urgent).",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "context" => %{"type" => "string", "description" => "Context slug"},
          "title" => %{"type" => "string", "description" => "Todo title"},
          "slug" => %{"type" => "string", "description" => "Todo slug (kebab-case)"},
          "goal_slug" => %{
            "type" => "string",
            "description" => "Goal this todo belongs to (optional)"
          },
          "body" => %{
            "type" => "string",
            "description" => "Todo description in markdown (optional)"
          },
          "priority" => %{
            "type" => "string",
            "description" => "low, medium, high, urgent (default: medium)",
            "enum" => ["low", "medium", "high", "urgent"]
          },
          "kanban_status" => %{
            "type" => "string",
            "description" =>
              "backlog, this_week, today, in_progress, done, cancelled (default: backlog)",
            "enum" => ["backlog", "this_week", "today", "in_progress", "done", "cancelled"]
          },
          "due_date" => %{"type" => "string", "description" => "Due date YYYY-MM-DD (optional)"},
          "owner" => %{"type" => "string", "description" => "Owner identity (defaults to system)"},
          "created_by" => %{
            "type" => "string",
            "description" => "Who created this todo (defaults to system)"
          }
        },
        "required" => ["context", "title", "slug"]
      }
    },
    %{
      "name" => "lint",
      "description" =>
        "Run a quality lint report for a context. Returns orphans (pages with no inbound links), broken wikilinks ([[slug]] pointing to non-existent pages), stale pages (not updated in 90 days), and contested knowledge. Use this to identify maintenance tasks.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "context" => %{"type" => "string", "description" => "Context slug"}
        },
        "required" => ["context"]
      }
    },
    %{
      "name" => "ingest_url",
      "description" =>
        "Save a URL into the second brain. For web pages (HTML), saves the URL as a reference page — the agent can read the content later via the URL. For files (PDF, documents, images), downloads and stores the file, creating a reference with a download link. Does NOT extract or parse content — that's the agent's job.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "context" => %{"type" => "string", "description" => "Context slug"},
          "url" => %{"type" => "string", "description" => "URL to ingest (HTML article or PDF)"},
          "slug" => %{
            "type" => "string",
            "description" => "Custom slug (auto from title if omitted)"
          },
          "tags" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Tags (optional)"
          }
        },
        "required" => ["context", "url"]
      }
    },
    %{
      "name" => "delete_page",
      "description" =>
        "Delete a page by slug. Cascades to relations and page versions. This is irreversible — confirm with the user before deleting. Logs the action to the audit log.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "context" => %{"type" => "string", "description" => "Context slug"},
          "slug" => %{"type" => "string", "description" => "Slug of the page to delete"}
        },
        "required" => ["context", "slug"]
      }
    },
    %{
      "name" => "create_relation",
      "description" =>
        "Create a typed relation between two pages. Relation types: 'related' (generic connection), 'contradicts' (source contradicts target), 'supersedes' (source replaces target), 'part_of' (source is part of target), 'embeds' (source embeds target). Use this for explicit relationships beyond what wikilinks auto-create.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "context" => %{"type" => "string", "description" => "Context slug"},
          "source_slug" => %{"type" => "string", "description" => "Slug of the source page"},
          "target_slug" => %{"type" => "string", "description" => "Slug of the target page"},
          "relation_type" => %{
            "type" => "string",
            "description" => "Type of relation",
            "enum" => ["related", "contradicts", "supersedes", "part_of", "embeds"]
          }
        },
        "required" => ["context", "source_slug", "target_slug"]
      }
    },
    %{
      "name" => "get_links",
      "description" =>
        "Get all inbound and outbound relations for a page. Returns outbound (pages this page links to) and inbound (pages that link to this page), with relation types.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "context" => %{"type" => "string", "description" => "Context slug"},
          "slug" => %{"type" => "string", "description" => "Page slug"}
        },
        "required" => ["context", "slug"]
      }
    },
    %{
      "name" => "list_pages",
      "description" =>
        "List pages in a context with optional filters. Returns lightweight metadata (no body) by default. Use type filter to list specific page types (e.g. todos, goals). Useful for getting an overview without fetching full content.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "context" => %{"type" => "string", "description" => "Context slug"},
          "type" => %{
            "type" => "string",
            "description" =>
              "Filter by page type: note, concept, entity, reference, goal, plan, todo, artifact, comparison (optional)",
            "enum" => [
              "note",
              "concept",
              "entity",
              "reference",
              "goal",
              "plan",
              "todo",
              "artifact",
              "comparison"
            ]
          },
          "tag" => %{"type" => "string", "description" => "Filter by tag (optional)"},
          "status" => %{
            "type" => "string",
            "description" =>
              "Filter by kanban_status (for todos): backlog, this_week, today, in_progress, done, cancelled (optional)"
          },
          "limit" => %{"type" => "integer", "description" => "Max results (default 50, max 500)"}
        },
        "required" => ["context"]
      }
    },
    %{
      "name" => "update_todo",
      "description" =>
        "Update a todo's kanban status, priority, due date, or goal. Merges meta — you only need to pass the fields you want to change, existing meta is preserved.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "context" => %{"type" => "string", "description" => "Context slug"},
          "slug" => %{"type" => "string", "description" => "Todo slug to update"},
          "kanban_status" => %{
            "type" => "string",
            "description" => "New kanban status (optional)",
            "enum" => ["backlog", "this_week", "today", "in_progress", "done", "cancelled"]
          },
          "priority" => %{
            "type" => "string",
            "description" => "New priority (optional)",
            "enum" => ["low", "medium", "high", "urgent"]
          },
          "due_date" => %{
            "type" => "string",
            "description" => "New due date YYYY-MM-DD (optional)"
          },
          "goal_slug" => %{
            "type" => "string",
            "description" => "New goal slug to link this todo to (optional)"
          },
          "title" => %{"type" => "string", "description" => "New title (optional)"},
          "body" => %{"type" => "string", "description" => "New body in markdown (optional)"},
          "tags" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "New tags (optional, replaces existing)"
          }
        },
        "required" => ["context", "slug"]
      }
    },
    %{
      "name" => "delete_relation",
      "description" =>
        "Delete a relation between two pages. If relation_type is provided, only deletes that type. Otherwise, deletes ALL relations between the two pages (both directions). Use get_links first to see what relations exist.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "context" => %{"type" => "string", "description" => "Context slug"},
          "source_slug" => %{"type" => "string", "description" => "Slug of the source page"},
          "target_slug" => %{"type" => "string", "description" => "Slug of the target page"},
          "relation_type" => %{
            "type" => "string",
            "description" =>
              "Only delete relations of this type (optional, deletes all if omitted)",
            "enum" => ["related", "contradicts", "supersedes", "part_of", "embeds"]
          }
        },
        "required" => ["context", "source_slug", "target_slug"]
      }
    },
    %{
      "name" => "stats",
      "description" =>
        "Get aggregate statistics for a context. Returns total pages, pages by type, todos by kanban status, orphan count, broken link count, and total relations. Use this for dashboard-style overviews and weekly reviews.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "context" => %{"type" => "string", "description" => "Context slug"}
        },
        "required" => ["context"]
      }
    },
    %{
      "name" => "rename_slug",
      "description" =>
        "Rename a page's slug and automatically update all wikilinks [[old-slug]] and embeds ![[old-slug]] across the entire context to use the new slug. Use this when a page was created with a wrong slug. The page itself is also updated.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "context" => %{"type" => "string", "description" => "Context slug"},
          "old_slug" => %{"type" => "string", "description" => "Current slug to rename"},
          "new_slug" => %{"type" => "string", "description" => "New slug (kebab-case)"}
        },
        "required" => ["context", "old_slug", "new_slug"]
      }
    }
  ]

  @resources [
    %{
      "uri" => "page://{context}/{slug}",
      "name" => "Page content",
      "description" => "Full page content as markdown",
      "mimeType" => "text/markdown"
    },
    %{
      "uri" => "goal://{context}/{slug}",
      "name" => "Goal detail",
      "description" => "Goal with related todos and plans",
      "mimeType" => "application/json"
    },
    %{
      "uri" => "wiki://{context}/index",
      "name" => "Wiki index",
      "description" => "All pages in a context (slug + title + type)",
      "mimeType" => "application/json"
    }
  ]

  @prompts [
    %{
      "name" => "research_topic",
      "description" => "Scaffold a research page with outline, sources, and questions.",
      "arguments" => [
        %{"name" => "topic", "description" => "The topic to research", "required" => true},
        %{"name" => "context", "description" => "Context slug", "required" => true}
      ]
    },
    %{
      "name" => "brainstorm",
      "description" => "Generate ideas around a topic.",
      "arguments" => [
        %{"name" => "topic", "description" => "The topic to brainstorm", "required" => true},
        %{"name" => "context", "description" => "Context slug", "required" => true}
      ]
    },
    %{
      "name" => "goal_review",
      "description" => "Review a goal's status, todos, and plans.",
      "arguments" => [
        %{"name" => "goal_slug", "description" => "Goal slug", "required" => true},
        %{"name" => "context", "description" => "Context slug", "required" => true}
      ]
    }
  ]

  # ── Public API for controller ──────────────────────────────────────────────

  @doc "Process a JSON-RPC message and return the response map"
  def process_message(msg) do
    case msg do
      %{"jsonrpc" => "2.0", "method" => "initialize", "id" => id} ->
        initialize_response(id)

      %{"jsonrpc" => "2.0", "method" => "initialized"} ->
        nil

      %{"jsonrpc" => "2.0", "method" => "tools/list", "id" => id} ->
        %{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => %{"tools" => @tools}
        }

      %{"jsonrpc" => "2.0", "method" => "tools/call", "id" => id, "params" => params} ->
        tool_name = params["name"]
        args = params["arguments"] || %{}
        result = execute_tool(tool_name, args)

        %{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => %{
            "content" => [%{"type" => "text", "text" => result}]
          }
        }

      %{"jsonrpc" => "2.0", "method" => "resources/list", "id" => id} ->
        %{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => %{"resources" => @resources}
        }

      %{"jsonrpc" => "2.0", "method" => "resources/read", "id" => id, "params" => params} ->
        uri = params["uri"]
        content = read_resource(uri)

        %{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => %{
            "contents" => [%{"uri" => uri, "mimeType" => "text/markdown", "text" => content}]
          }
        }

      %{"jsonrpc" => "2.0", "method" => "prompts/list", "id" => id} ->
        %{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => %{"prompts" => @prompts}
        }

      %{"jsonrpc" => "2.0", "method" => "prompts/get", "id" => id, "params" => params} ->
        prompt_name = params["name"]
        args = params["arguments"] || %{}
        messages = get_prompt(prompt_name, args)

        %{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => %{"messages" => messages}
        }

      %{"jsonrpc" => "2.0", "method" => _method, "id" => id} ->
        %{
          "jsonrpc" => "2.0",
          "id" => id,
          "error" => %{"code" => -32601, "message" => "Method not found"}
        }

      %{"jsonrpc" => "2.0", "method" => _method} ->
        nil

      _ ->
        %{
          "jsonrpc" => "2.0",
          "id" => nil,
          "error" => %{"code" => -32700, "message" => "Parse error"}
        }
    end
  end

  @doc "Check if a message is a notification (has method but no id)"
  def notification?(%{"jsonrpc" => "2.0", "method" => _} = msg), do: not Map.has_key?(msg, "id")
  def notification?(_), do: false

  @doc "Generate a new session ID"
  def generate_session_id do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  @doc "Get protocol version"
  def protocol_version, do: @protocol_version

  # ── Initialize ──────────────────────────────────────────────────────────────

  defp initialize_response(id) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "protocolVersion" => @protocol_version,
        "capabilities" => %{
          "tools" => %{},
          "resources" => %{},
          "prompts" => %{}
        },
        "serverInfo" => %{
          "name" => "dran",
          "version" => "0.1.0"
        }
      }
    }
  end

  # ── Tool execution ─────────────────────────────────────────────────────────

  defp execute_tool("search", %{"query" => query, "context" => context_slug} = args) do
    context = Brain.get_context_by_slug(context_slug)

    if context do
      opts = [context_id: context.id]
      opts = if args["type"], do: Keyword.put(opts, :type, args["type"]), else: opts
      opts = if args["strategy"], do: Keyword.put(opts, :strategy, args["strategy"]), else: opts

      case Brain.search(query, opts) do
        {:ok, results} ->
          lines =
            Enum.map(results, fn result ->
              distance_text =
                if result.distance,
                  do: " (distance: #{:erlang.float_to_binary(result.distance, decimals: 4)})",
                  else: ""

              source_text = " (source: #{result.source})"

              "- **#{result.title}** (`#{result.slug}`, type: #{result.page_type})#{distance_text}#{source_text}\n  #{result.excerpt}"
            end)

          Enum.join(lines, "\n\n")

        {:error, :not_configured} ->
          "Error: inference API is not configured"

        {:error, reason} ->
          "Error: #{inspect(reason)}"
      end
    else
      "Error: context '#{context_slug}' not found"
    end
  end

  defp execute_tool("semantic_search", %{} = args) do
    strategy = if args["hybrid"] == true, do: "hybrid", else: "semantic"
    execute_tool("search", Map.put(args, "strategy", strategy))
  end

  defp execute_tool(
         "create_page",
         %{"context" => context_slug, "title" => title, "slug" => slug, "page_type" => page_type} =
           args
       ) do
    context = Brain.get_context_by_slug(context_slug)

    if context do
      attrs =
        %{
          context_id: context.id,
          title: title,
          slug: slug,
          page_type: page_type,
          body: Map.get(args, "body", ""),
          tags: Map.get(args, "tags", []),
          summary: Map.get(args, "summary"),
          meta: Map.get(args, "meta", %{}),
          created_by: Map.get(args, "created_by", "agent"),
          owner: Map.get(args, "owner", "agent")
        }
        |> maybe_put(:on_behalf_of, args["on_behalf_of"])

      case Brain.create_page(attrs) do
        {:ok, page} ->
          Brain.resolve_wikilinks(page)
          "Created page: #{page.title} (#{page.slug})"

        {:error, changeset} ->
          "Error: #{format_changeset_errors(changeset)}"
      end
    else
      "Error: context '#{context_slug}' not found"
    end
  end

  defp execute_tool("update_page", %{"context" => context_slug, "slug" => slug} = args) do
    context = Brain.get_context_by_slug(context_slug)

    if context do
      case Brain.get_page_by_slug(slug, context.id) do
        nil ->
          "Error: page '#{slug}' not found in context '#{context_slug}'"

        page ->
          attrs =
            Map.take(args, ["title", "body", "tags", "meta", "summary"])
            |> Map.put("updated_by", Map.get(args, "updated_by", "agent"))

          case Brain.update_page(page, attrs) do
            {:ok, updated} ->
              Brain.resolve_wikilinks(updated)
              "Updated page: #{updated.title} (v#{updated.version})"

            {:error, changeset} ->
              "Error: #{format_changeset_errors(changeset)}"
          end
      end
    else
      "Error: context '#{context_slug}' not found"
    end
  end

  defp execute_tool("get_page", %{"context" => context_slug, "slug" => slug}) do
    context = Brain.get_context_by_slug(context_slug)

    if context do
      case Brain.get_page_by_slug(slug, context.id) do
        nil ->
          "Error: page '#{slug}' not found"

        page ->
          "# #{page.title}\n\n#{page.body}\n\n---\nType: #{page.page_type} | Tags: #{Enum.join(page.tags, ", ")} | Version: #{page.version}"
      end
    else
      "Error: context '#{context_slug}' not found"
    end
  end

  defp execute_tool(
         "create_todo",
         %{"context" => context_slug, "title" => title, "slug" => slug} = args
       ) do
    context = Brain.get_context_by_slug(context_slug)

    if context do
      meta =
        %{}
        |> Map.put("kanban_status", Map.get(args, "kanban_status", "backlog"))
        |> maybe_put_meta("goal_slug", args["goal_slug"])
        |> maybe_put_meta("priority", args["priority"])
        |> maybe_put_meta("due_date", args["due_date"])

      attrs = %{
        context_id: context.id,
        title: title,
        slug: slug,
        page_type: "todo",
        body: Map.get(args, "body", ""),
        meta: meta,
        created_by: Map.get(args, "created_by", "agent"),
        owner: Map.get(args, "owner", "agent")
      }

      case Brain.create_page(attrs) do
        {:ok, todo} ->
          status = Map.get(meta, "kanban_status")
          "Created todo: #{todo.title} (#{todo.slug}) — status: #{status}"

        {:error, changeset} ->
          "Error: #{format_changeset_errors(changeset)}"
      end
    else
      "Error: context '#{context_slug}' not found"
    end
  end

  defp execute_tool("lint", %{"context" => context_slug}) do
    context = Brain.get_context_by_slug(context_slug)

    if context do
      report = Brain.lint(context.id)

      """
      # Lint Report for '#{context_slug}'

      ## Orphan pages (no inbound links): #{length(report.orphans)}
      #{format_page_list(report.orphans)}

      ## Broken wikilinks: #{length(report.broken_wikilinks)}
      #{format_broken_links(report.broken_wikilinks)}

      ## Stale pages (>90 days): #{length(report.stale)}
      #{format_page_list(report.stale)}

      ## Contested pages: #{length(report.contested)}
      #{format_page_list(report.contested)}
      """
    else
      "Error: context '#{context_slug}' not found"
    end
  end

  defp execute_tool("ingest_url", %{"context" => context_slug, "url" => url} = args) do
    context = Brain.get_context_by_slug(context_slug)

    if context do
      case DranWeb.API.IngestController.do_ingest(context, url, args) do
        {:ok, page} ->
          "Ingested '#{page.title}' as #{page.page_type} (#{page.slug}) from #{url}"

        {:error, reason} ->
          "Error: failed to ingest URL: #{reason}"
      end
    else
      "Error: context '#{context_slug}' not found"
    end
  end

  defp execute_tool("delete_page", %{"context" => context_slug, "slug" => slug}) do
    context = Brain.get_context_by_slug(context_slug)

    if context do
      case Brain.get_page_by_slug(slug, context.id) do
        nil ->
          "Error: page '#{slug}' not found in context '#{context_slug}'"

        page ->
          case Brain.delete_page(page) do
            {:ok, _} ->
              "Deleted page: #{page.title} (#{page.slug})"

            {:error, _} ->
              "Error: could not delete page '#{slug}'"
          end
      end
    else
      "Error: context '#{context_slug}' not found"
    end
  end

  defp execute_tool(
         "create_relation",
         %{"context" => context_slug, "source_slug" => source_slug, "target_slug" => target_slug} =
           args
       ) do
    context = Brain.get_context_by_slug(context_slug)

    if context do
      relation_type = Map.get(args, "relation_type", "related")

      case Brain.create_relation_by_slugs(source_slug, target_slug, relation_type, context.id) do
        {:ok, _relation} ->
          "Created relation: #{source_slug} --#{relation_type}--> #{target_slug}"

        {:error, :source_not_found} ->
          "Error: source page '#{source_slug}' not found"

        {:error, :target_not_found} ->
          "Error: target page '#{target_slug}' not found"

        {:error, changeset} ->
          "Error: #{format_changeset_errors(changeset)}"
      end
    else
      "Error: context '#{context_slug}' not found"
    end
  end

  defp execute_tool("get_links", %{"context" => context_slug, "slug" => slug}) do
    context = Brain.get_context_by_slug(context_slug)

    if context do
      case Brain.get_page_by_slug(slug, context.id) do
        nil ->
          "Error: page '#{slug}' not found"

        page ->
          relations = Brain.list_relations_for_page(page.id)

          outbound =
            Enum.map(relations.outbound, fn rel ->
              "- --#{rel.relation_type}--> #{rel.target.title} (`#{rel.target.slug}`)"
            end)

          inbound =
            Enum.map(relations.inbound, fn rel ->
              "- #{rel.source.title} (`#{rel.source.slug}`) --#{rel.relation_type}-->"
            end)

          """
          # Relations for '#{page.title}'

          ## Outbound (#{length(outbound)})
          #{Enum.join(outbound, "\n")}

          ## Inbound (#{length(inbound)})
          #{Enum.join(inbound, "\n")}
          """
      end
    else
      "Error: context '#{context_slug}' not found"
    end
  end

  defp execute_tool("list_pages", %{"context" => context_slug} = args) do
    context = Brain.get_context_by_slug(context_slug)

    if context do
      limit = min(Map.get(args, "limit", 50), 500)

      opts = [context_id: context.id, limit: limit]
      opts = if args["type"], do: Keyword.put(opts, :type, args["type"]), else: opts
      opts = if args["tag"], do: Keyword.put(opts, :tag, args["tag"]), else: opts
      opts = if args["status"], do: Keyword.put(opts, :status, args["status"]), else: opts

      pages = Brain.list_pages(opts)

      lines =
        Enum.map(pages, fn page ->
          "- **#{page.title}** (`#{page.slug}`, type: #{page.page_type})"
        end)

      "Found #{length(pages)} pages:\n\n#{Enum.join(lines, "\n")}"
    else
      "Error: context '#{context_slug}' not found"
    end
  end

  defp execute_tool("update_todo", %{"context" => context_slug, "slug" => slug} = args) do
    context = Brain.get_context_by_slug(context_slug)

    if context do
      case Brain.get_page_by_slug(slug, context.id) do
        nil ->
          "Error: todo '#{slug}' not found"

        todo ->
          # Merge meta: start with existing, overlay changes
          existing_meta = todo.meta || %{}

          new_meta =
            existing_meta
            |> maybe_put_meta("kanban_status", args["kanban_status"])
            |> maybe_put_meta("priority", args["priority"])
            |> maybe_put_meta("due_date", args["due_date"])
            |> maybe_put_meta("goal_slug", args["goal_slug"])

          attrs = %{"meta" => new_meta}
          attrs = Map.put(attrs, "updated_by", "agent")
          attrs = if args["title"], do: Map.put(attrs, "title", args["title"]), else: attrs
          attrs = if args["body"], do: Map.put(attrs, "body", args["body"]), else: attrs
          attrs = if args["tags"], do: Map.put(attrs, "tags", args["tags"]), else: attrs

          case Brain.update_page(todo, attrs) do
            {:ok, updated} ->
              status = get_in(updated.meta, ["kanban_status"]) || "unknown"
              "Updated todo: #{updated.title} (#{updated.slug}) — status: #{status}"

            {:error, changeset} ->
              "Error: #{format_changeset_errors(changeset)}"
          end
      end
    else
      "Error: context '#{context_slug}' not found"
    end
  end

  defp execute_tool(
         "delete_relation",
         %{"context" => context_slug, "source_slug" => source_slug, "target_slug" => target_slug} =
           args
       ) do
    context = Brain.get_context_by_slug(context_slug)

    if context do
      relation_type = Map.get(args, "relation_type")

      case Brain.delete_relation_by_slugs(source_slug, target_slug, relation_type, context.id) do
        {count, []} ->
          "Deleted #{count} relation(s) between '#{source_slug}' and '#{target_slug}'"

        {count, errors} ->
          "Deleted #{count} relation(s), but encountered errors: #{Enum.join(errors, ", ")}"
      end
    else
      "Error: context '#{context_slug}' not found"
    end
  end

  defp execute_tool("stats", %{"context" => context_slug}) do
    context = Brain.get_context_by_slug(context_slug)

    if context do
      s = Brain.stats(context.id)

      by_type =
        s.by_type
        |> Enum.map(fn {type, count} -> "- #{type}: #{count}" end)
        |> Enum.join("\n")

      todos_by_status =
        s.todos_by_status
        |> Enum.map(fn {status, count} -> "- #{status}: #{count}" end)
        |> Enum.join("\n")

      """
      # Stats for '#{context_slug}'

      Total pages: #{s.total_pages}
      Total relations: #{s.total_relations}
      Orphan pages: #{s.orphan_count}
      Broken wikilinks: #{s.broken_link_count}

      ## Pages by type
      #{by_type}

      ## Todos by status
      #{todos_by_status}
      """
    else
      "Error: context '#{context_slug}' not found"
    end
  end

  defp execute_tool(
         "rename_slug",
         %{"context" => context_slug, "old_slug" => old_slug, "new_slug" => new_slug}
       ) do
    context = Brain.get_context_by_slug(context_slug)

    if context do
      if old_slug == new_slug do
        "Error: old_slug and new_slug are the same"
      else
        case Brain.get_page_by_slug(old_slug, context.id) do
          nil ->
            "Error: page '#{old_slug}' not found"

          page ->
            # Check that new_slug doesn't already exist
            case Brain.get_page_by_slug(new_slug, context.id) do
              nil ->
                # 1. Relink all wikilinks/embeds across the context
                {relinked_count, _} = Brain.relink_wikilinks(context.id, old_slug, new_slug)

                # 2. Update the page's own slug
                case Brain.update_page(page, %{"slug" => new_slug, "updated_by" => "agent"}) do
                  {:ok, _updated} ->
                    "Renamed '#{old_slug}' → '#{new_slug}' and relinked #{relinked_count} page(s)"

                  {:error, changeset} ->
                    "Error: relinked #{relinked_count} page(s) but failed to rename page: #{format_changeset_errors(changeset)}"
                end

              _existing ->
                "Error: a page with slug '#{new_slug}' already exists"
            end
        end
      end
    else
      "Error: context '#{context_slug}' not found"
    end
  end

  defp execute_tool(tool_name, _args) do
    "Error: unknown tool '#{tool_name}'"
  end

  # ── Resource reading ──────────────────────────────────────────────────────

  defp read_resource("page://" <> rest) do
    [context_slug, slug] = String.split(rest, "/", parts: 2)
    context = Brain.get_context_by_slug(context_slug)

    if context do
      case Brain.get_page_by_slug(slug, context.id) do
        nil ->
          "Error: page not found"

        page ->
          "# #{page.title}\n\n#{page.body}\n\n---\nType: #{page.page_type} | Tags: #{Enum.join(page.tags, ", ")}"
      end
    else
      "Error: context not found"
    end
  end

  defp read_resource("goal://" <> rest) do
    [context_slug, slug] = String.split(rest, "/", parts: 2)
    context = Brain.get_context_by_slug(context_slug)

    if context do
      case Brain.get_page_by_slug(slug, context.id) do
        nil ->
          "Error: goal not found"

        goal ->
          todos =
            Brain.list_pages(
              context_id: context.id,
              type: "todo",
              limit: 500,
              include_body: false
            )

          goal_todos = Enum.filter(todos, fn t -> get_in(t.meta, ["goal_slug"]) == slug end)

          plans =
            Brain.list_pages(
              context_id: context.id,
              type: "plan",
              limit: 100,
              include_body: false
            )

          goal_plans = Enum.filter(plans, fn p -> get_in(p.meta, ["goal_slug"]) == slug end)

          Jason.encode!(%{
            goal: %{title: goal.title, slug: goal.slug, body: goal.body},
            todos:
              Enum.map(
                goal_todos,
                &%{title: &1.title, slug: &1.slug, status: get_in(&1.meta, ["kanban_status"])}
              ),
            plans: Enum.map(goal_plans, &%{title: &1.title, slug: &1.slug})
          })
      end
    else
      "Error: context not found"
    end
  end

  defp read_resource("wiki://" <> rest) do
    [context_slug, "index"] = String.split(rest, "/", parts: 2)
    context = Brain.get_context_by_slug(context_slug)

    if context do
      pages = Brain.list_pages(context_id: context.id, limit: 10_000)

      lines =
        Enum.map(pages, fn page ->
          "- `#{page.slug}` — #{page.title} (#{page.page_type})"
        end)

      Enum.join(lines, "\n")
    else
      "Error: context not found"
    end
  end

  defp read_resource(_uri) do
    "Error: unknown resource URI format"
  end

  # ── Prompts ─────────────────────────────────────────────────────────────────

  defp get_prompt("research_topic", %{"topic" => topic, "context" => context}) do
    [
      %{
        "role" => "user",
        "content" => %{
          "type" => "text",
          "text" => """
          Research the topic: #{topic}

          1. Create an outline for a research page
          2. List key sources to consult
          3. Formulate 3-5 research questions
          4. Suggest tags and wikilinks to related topics

          Save the result as a page in context '#{context}' using the create_page tool.
          """
        }
      }
    ]
  end

  defp get_prompt("brainstorm", %{"topic" => topic, "context" => context}) do
    [
      %{
        "role" => "user",
        "content" => %{
          "type" => "text",
          "text" => """
          Brainstorm ideas around: #{topic}

          Generate 5-10 ideas as pages in context '#{context}'.
          Use page_type 'note' with meta.kind 'idea' and interlink them with wikilinks where relevant.
          """
        }
      }
    ]
  end

  defp get_prompt("goal_review", %{"goal_slug" => slug, "context" => context}) do
    [
      %{
        "role" => "user",
        "content" => %{
          "type" => "text",
          "text" => """
          Review goal '#{slug}' in context '#{context}'.

          1. Get the goal page and all its todos and plans
          2. Summarize current status
          3. Identify blockers and overdue items
          4. Suggest next actions
          """
        }
      }
    ]
  end

  defp get_prompt(_name, _args) do
    [
      %{
        "role" => "user",
        "content" => %{"type" => "text", "text" => "Error: unknown prompt"}
      }
    ]
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp format_page_list(pages) do
    pages
    |> Enum.map(fn p -> "- #{p.title} (`#{p.slug}`)" end)
    |> Enum.join("\n")
  end

  defp format_broken_links(links) do
    links
    |> Enum.map(fn %{page_slug: page_slug, missing_slug: missing} ->
      "- `#{page_slug}` references missing `#{missing}`"
    end)
    |> Enum.join("\n")
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

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_meta(map, _key, nil), do: map
  defp maybe_put_meta(map, _key, ""), do: map
  defp maybe_put_meta(map, key, value), do: Map.put(map, key, value)
end
