defmodule Dran.MCP do
  @moduledoc """
  MCP (Model Context Protocol) server for Dran — Streamable HTTP transport.

  Served from Phoenix at `/api/mcp`. Supports POST and DELETE per
  MCP spec 2025-03-26 Streamable HTTP transport.

  ## Endpoints
  - `POST /api/mcp` — send JSON-RPC request → JSON response
  - `GET /api/mcp` — responds 405 (SSE stream not implemented)
  - `DELETE /api/mcp` — terminate session

  ## Tools (19)
  - `dran_search` — use FIRST to find anything; strategy=auto picks best available
  - `dran_create_page` — create notes, concepts, entities, and references
  - `dran_update_page` — update page fields; REPLACES meta entirely (not a merge)
  - `dran_get_page` — read full page body by slug; use after dran_search/dran_list_pages, not before
  - `dran_delete_page` — delete a page by slug; **irreversible** (cascades to relations + versions)
  - `dran_create_note` — create a note with kind:"todo" + kanban fields (todo-style note)
  - `dran_update_note` — update a note's kanban fields; MERGES meta (pass only what changes)
  - `dran_create_goal` — create a first-class goal (its own table, not a page)
  - `dran_create_relation` — create a typed relation between two pages
  - `dran_delete_relation` — delete a relation between two pages; **irreversible**
  - `dran_get_links` — graph exploration: inbound + outbound relations of a page
  - `dran_list_pages` — lightweight listing with filters (type/tag/status/owner/assignee/props); prefer home:// resource for full index
  - `dran_get_stats` — context dashboard numbers: totals, by-type, todos by status, orphans
  - `dran_lint_brain` — brain hygiene audit: orphans, stale pages (>90d), contested knowledge (read-only)
  - `dran_rename_slug` — rename a page slug; auto-rewrites all `![[old-slug]]` embeds in the context
  - `dran_reaugment_page` — re-run augmentation (summary/tags/embedding/relations); use after major edits
  - `dran_start_agent` — start an autonomous agent (curator, link_gardener, graph_rag)
  - `dran_get_agent_session` — poll an agent session for status and steps
  - `dran_generate_cluster_summaries` — generate LLM summaries for all clusters in a context

  ## Embeds
  Embeds are auto-resolved into embeds relations on create and update; stale ones
  are removed on body update. Use `![[other-slug]]` in a page body to embed another
  page. `dran_rename_slug` rewrites embed references across the whole context.

  ## Resources
  - `page://{workspace}/{slug}` — page content as markdown
  - `goal://{workspace}/{slug}` — goal detail with todos and plans
  - `home://{workspace}/index` — home index (all slugs + titles)

  ## Prompts
  - `brainstorm` — generate ideas around a topic
  - `goal_review` — review a goal's status
  """

  alias Dran.{Agent, Auth, Goals, Knowledge, Repo}
  alias Dran.PageTypes
  alias DranWeb.ResourceAuthorization
  alias Dran.Goals
  import Ecto.Query, warn: false

  @protocol_version "2025-03-26"

  # ── Context cache (P-01) ───────────────────────────────────────────────────
  # ETS table for workspace_slug → %Workspace{} lookups. Contexts change rarely
  # (only in Settings), so caching is safe. The table is created lazily on
  # first access to avoid boot-order issues in tests.

  @context_cache_table :dran_mcp_workspace_cache

  defp workspace_cache_get(slug) do
    ensure_context_cache_table()

    case :ets.lookup(@context_cache_table, slug) do
      [{^slug, context}] -> context
      [] -> workspace_cache_load(slug)
    end
  end

  defp workspace_cache_load(slug) do
    context = Knowledge.get_workspace_by_slug(slug)

    if context do
      :ets.insert(@context_cache_table, {slug, context})
    end

    context
  end

  defp ensure_context_cache_table do
    case :ets.info(@context_cache_table) do
      :undefined ->
        :ets.new(@context_cache_table, [:set, :named_table, :public, {:read_concurrency, true}])

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  @tools [
    %{
      "name" => "dran_search",
      "description" =>
        "Use this FIRST whenever you need to find anything in the brain — a concept, note, entity, or any page. Returns matching pages with title, slug, type, excerpt, relevance distance, and search source (fts/fuzzy/semantic/hybrid). Strategy defaults to 'auto', which picks the best available method automatically — you rarely need to set it explicitly. Use `type` to narrow results to a page type. Semantic/hybrid strategies require the inference API; they degrade to fts if inference is not configured, which you can detect from the returned `source` field.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "query" => %{
            "type" => "string",
            "description" =>
              "Natural-language search query. Keywords or a full sentence both work; fuzzy/semantic strategies handle typos and paraphrase."
          },
          "workspace" => %{
            "type" => "string",
            "description" => "Context slug to search within, e.g. 'personal' or 'work'."
          },
          "type" => %{
            "type" => "string",
            "description" =>
              "Optional filter restricting results to a single page type: note, concept, entity, or reference.",
            "enum" => [
              "note",
              "concept",
              "entity",
              "reference"
            ]
          },
          "strategy" => %{
            "type" => "string",
            "enum" => ["auto", "fts", "fuzzy", "semantic", "hybrid"],
            "description" =>
              "Search strategy. 'auto' (default) picks the best available. 'fts' = PostgreSQL full-text (fast, keyword). 'fuzzy' = trigram similarity (typo-tolerant). 'semantic' = vector embedding similarity (requires inference API). 'hybrid' = fts + semantic combined (requires inference API). Semantic/hybrid fall back to fts if inference is unavailable — check the returned `source` to confirm which strategy ran."
          },
          "limit" => %{
            "type" => "integer",
            "description" => "Maximum number of results (default 20, hard max 100)."
          },
          "props" => %{
            "type" => "object",
            "description" =>
              "Filter by custom properties (meta.props). Matches pages where ALL given key-value pairs are present (AND logic). Example: {\"role\": \"sales\", \"tier\": \"vip\"}"
          },
          "offset" => %{
            "type" => "integer",
            "description" =>
              "Number of results to skip for pagination (default 0). Use with limit to paginate large result sets."
          }
        },
        "required" => ["query", "workspace"]
      }
    },
    %{
      "name" => "dran_create_page",
      "description" => """
      Use for notes, concepts, entities, and references (page types only). Goals are first-class entities — use `dran_create_goal` for those. Projects are notes with `meta.kind: "project"`, created with this same tool. Notes with todo-style kanban tracking use `dran_create_note` instead. Each page has a `page_type` that determines its purpose and what metadata (`meta`) it accepts. If `slug` is omitted it is derived from the title; if `title` is omitted it is derived from the body. **Caveat: creation fails if the slug already exists in the given context** — use `dran_update_page` or `dran_rename_slug` in that case. Use `![[other-slug]]` inside `body` to embed another page; embeds are auto-resolved into `embeds` relations.

      Page types and subtypes (set `meta.kind`):
      #{Dran.PageRegistry.mcp_description()}

      The `report` page type is system-only: reports are created by Dran itself (jobs, system output) and CANNOT be created via this tool — they live outside the graph, journey and embeddings, and are visible in the activity log and at /reports/:slug in the web UI.
      """,
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "workspace" => %{
            "type" => "string",
            "description" => "Context slug where the page will be created."
          },
          "title" => %{
            "type" => "string",
            "description" =>
              "Human-readable page title. If omitted, derived from the body's first line."
          },
          "slug" => %{
            "type" => "string",
            "description" =>
              "URL-friendly kebab-case slug, unique per context. If omitted, derived from the title. Creation fails if this slug already exists in the context — use dran_update_page or dran_rename_slug instead."
          },
          "body" => %{
            "type" => "string",
            "description" =>
              "Page content in Markdown. Use `![[other-slug]]` to embed another page; embeds are auto-resolved into `embeds` relations."
          },
          "page_type" => %{
            "type" => "string",
            "description" =>
              "Page type determining purpose and accepted meta fields. Only note, concept, entity, and reference are available. Use dran_create_goal for goals, dran_create_note for todo-style notes.",
            "enum" => Dran.PageRegistry.mcp_enum()
          },
          "tags" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Tags in kebab-case, e.g. [\"elixir\", \"testing\"]."
          },
          "meta" => %{
            "type" => "object",
            "description" => Dran.PageRegistry.mcp_meta_description()
          },
          "summary" => %{
            "type" => "string",
            "description" => "Optional one-line summary shown in listings."
          },
          "owner" => %{
            "type" => "string",
            "description" =>
              "Owner identity for the page. Derived from the API key name — not client-settable. Defaults to 'system' when no API key is present."
          },
          "created_by" => %{
            "type" => "string",
            "description" =>
              "Who created this page, recorded for provenance. Defaults to the authenticated identity (API key name or user email). Override only when you need to attribute creation to a different actor."
          },
          "on_behalf_of" => %{
            "type" => "string",
            "description" => "Who an agent is acting on behalf of (optional)."
          }
        },
        "required" => ["workspace", "page_type"]
      }
    },
    %{
      "name" => "dran_update_page",
      "description" =>
        "Update an existing page by slug. Pass only the fields you want to change (title, body, tags, meta, summary, owner, created_by, on_behalf_of, kb_confidence, kb_source_url, kb_contested, archived). **Note: `meta` is REPLACED entirely, not merged** — include all existing keys you want to keep. For notes with kanban fields (todo-style notes), prefer `dran_update_note` which merges meta. Changing `body` auto-increments the page version and re-resolves `![[slug]]` embeds into relations. Returns the new title and version number. Returns an error if the page slug is not found in the context.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "workspace" => %{
            "type" => "string",
            "description" => "Context slug containing the page."
          },
          "slug" => %{
            "type" => "string",
            "description" => "Slug of the page to update."
          },
          "title" => %{
            "type" => "string",
            "description" => "New title (optional)."
          },
          "body" => %{
            "type" => "string",
            "description" =>
              "New Markdown body (optional). Changing this increments the version and re-resolves `![[slug]]` embeds."
          },
          "tags" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "New tags list (optional, replaces existing tags)."
          },
          "meta" => %{
            "type" => "object",
            "description" =>
              "Updated metadata map (optional). Replaces the entire `meta` object, so include existing keys you want to keep."
          },
          "summary" => %{
            "type" => "string",
            "description" => "New one-line summary (optional)."
          },
          "owner" => %{
            "type" => "string",
            "description" => "New owner identity for the page (optional)."
          },
          "created_by" => %{
            "type" => "string",
            "description" =>
              "Override who created this page (optional, for provenance corrections)."
          },
          "on_behalf_of" => %{
            "type" => "string",
            "description" => "Set or clear who an agent is acting on behalf of (optional)."
          },
          "updated_by" => %{
            "type" => "string",
            "description" => "Who is updating the page, for provenance (defaults to 'agent')."
          },
          "archived" => %{
            "type" => "boolean",
            "description" =>
              "Archive (true) or unarchive (false) the page (optional). Archived pages disappear from lists, stats, search, and kanban but stay accessible by slug."
          },
          "kb_confidence" => %{
            "type" => "string",
            "description" =>
              "Knowledge-base confidence level (optional): low, medium, high, or verified.",
            "enum" => ["low", "medium", "high", "verified"]
          },
          "kb_source_url" => %{
            "type" => "string",
            "description" => "Source URL for the page's knowledge-base entry (optional)."
          },
          "kb_contested" => %{
            "type" => "boolean",
            "description" => "Mark the page's knowledge as contested/uncertain (optional)."
          }
        },
        "required" => ["workspace", "slug"]
      }
    },
    %{
      "name" => "dran_get_page",
      "description" =>
        "Read the full body of a page by slug. Use after `dran_search` or `dran_list_pages` to actually read content, not before — those tools give you the slug you need. Returns the full Markdown body plus a metadata footer (type, tags, version). For a lightweight metadata-only listing, use `dran_list_pages` instead. Returns an error if the slug is not found in the context.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "workspace" => %{
            "type" => "string",
            "description" => "Context slug containing the page."
          },
          "slug" => %{
            "type" => "string",
            "description" => "Slug of the page to read."
          }
        },
        "required" => ["workspace", "slug"]
      }
    },
    %{
      "name" => "dran_create_note",
      "description" =>
        "Create a plain note page (journal, idea, meeting…). DEPRECATED for todo-style tracking: use `dran_create_task` instead — tasks are first-class kanban items with status/priority/due_date/recurrence, and `kind:\"todo\"` no longer exists on notes. Link notes to goals/projects via dran_create_relation (relation_type `part_of`). Returns the created note's slug.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "workspace" => %{
            "type" => "string",
            "description" => "Context slug where the note will be created."
          },
          "title" => %{
            "type" => "string",
            "description" => "Note title (human-readable)."
          },
          "slug" => %{
            "type" => "string",
            "description" =>
              "URL-friendly kebab-case slug, unique per context. Creation fails if it already exists — use dran_update_note, dran_update_page, or dran_rename_slug instead."
          },
          "body" => %{
            "type" => "string",
            "description" => "Note description in Markdown (optional)."
          },
          "kind" => %{
            "type" => "string",
            "description" =>
              "Meta kind for the note. Defaults to \"todo\" for todo-style notes. Accepts any note kind (journal, idea, meeting, question, quote, reminder, code, recipe, debug, summary, decision, template, todo, plan, project)."
          },
          "priority" => %{
            "type" => "string",
            "description" => "Priority level: low, medium, high, or urgent (default: medium).",
            "enum" => ["low", "medium", "high", "urgent"]
          },
          "kanban_status" => %{
            "type" => "string",
            "description" =>
              "Kanban board column: backlog, todo, in_progress, done, or cancelled (default: backlog). Typical progression: backlog → todo → in_progress → done.",
            "enum" => ["backlog", "todo", "in_progress", "done", "cancelled"]
          },
          "due_date" => %{
            "type" => "string",
            "description" => "Due date in YYYY-MM-DD format (optional)."
          },
          "assignee" => %{
            "type" => "string",
            "description" =>
              "Who will execute this note (optional). Free-form string identifying the actor — e.g. 'alvaro' (human), 'hermes' (agent), 'claude-code' (coding agent). Omit for unassigned inbox items."
          },
          "owner" => %{
            "type" => "string",
            "description" =>
              "Owner identity for the note. Derived from the API key name — not client-settable. Defaults to 'system' when no API key is present."
          },
          "created_by" => %{
            "type" => "string",
            "description" =>
              "Who created this note, for provenance. Defaults to the authenticated identity (API key name or user email). Override only when you need to attribute creation to a different actor."
          },
          "on_behalf_of" => %{
            "type" => "string",
            "description" => "Who an agent is acting on behalf of (optional)."
          }
        },
        "required" => ["workspace", "title", "slug"]
      }
    },
    %{
      "name" => "dran_create_goal",
      "description" =>
        "Create a first-class goal (stored in its own table, NOT a page). Goals carry an OKR-style shape: kind, health (green/yellow/red), status, an optional metric with target_value/current_value/unit, start_date, target_date, and a team list. Link pages to the goal later with dran_create_relation (relation_type `part_of`, target_slug = the goal's slug). Creation fails if the slug already exists in the context. Returns the created goal's slug and status.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "workspace" => %{
            "type" => "string",
            "description" => "Context slug where the goal will be created."
          },
          "title" => %{
            "type" => "string",
            "description" => "Goal title (human-readable)."
          },
          "slug" => %{
            "type" => "string",
            "description" =>
              "URL-friendly kebab-case slug, unique per context. If omitted, derived from the title. Creation fails if it already exists."
          },
          "description" => %{
            "type" => "string",
            "description" => "Short one-line description of the goal (optional)."
          },
          "body" => %{
            "type" => "string",
            "description" => "Goal body in Markdown (optional)."
          },
          "kind" => %{
            "type" => "string",
            "description" =>
              "Goal kind: personal, coding, business, learning, health, finance, other, investing, marketing, product, writing, career, relationship, travel (optional).",
            "enum" => [
              "personal",
              "coding",
              "business",
              "learning",
              "health",
              "finance",
              "other",
              "investing",
              "marketing",
              "product",
              "writing",
              "career",
              "relationship",
              "travel"
            ]
          },
          "health" => %{
            "type" => "string",
            "description" =>
              "Goal health: green (on track), yellow (needs attention), or red (at risk).",
            "enum" => ["green", "yellow", "red"]
          },
          "status" => %{
            "type" => "string",
            "description" =>
              "Goal status: draft, active, on_hold, done, or archived (default: active).",
            "enum" => ["draft", "active", "on_hold", "done", "archived"]
          },
          "metric" => %{
            "type" => "string",
            "description" =>
              "Metric name the goal is measured by (optional), e.g. 'monthly revenue'."
          },
          "target_value" => %{
            "type" => "number",
            "description" => "Target value for the metric (optional)."
          },
          "current_value" => %{
            "type" => "number",
            "description" => "Current value of the metric (optional)."
          },
          "unit" => %{
            "type" => "string",
            "description" => "Unit for the metric values (optional), e.g. 'USD', 'hours'."
          },
          "start_date" => %{
            "type" => "string",
            "description" => "Start date in YYYY-MM-DD format (optional)."
          },
          "target_date" => %{
            "type" => "string",
            "description" => "Target/end date in YYYY-MM-DD format (optional)."
          },
          "team" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "List of team members or agents working on the goal (optional)."
          }
        },
        "required" => ["workspace", "title"]
      }
    },
    %{
      "name" => "dran_create_task",
      "description" =>
        "Create a first-class task (stored in its own `tasks` table, NOT a page). Tasks are the kanban action items: status backlog → todo → in_progress → done | cancelled, priority, due_date, recurrence (none/daily/weekly/monthly — completing a recurring task auto-clones the next occurrence) and a checklist in meta. Link the task to a goal or project/plan note OPTIONALLY via dran_create_relation (relation_type `part_of`, source_type `task`, source_id = the task id) — tasks exist standalone by default. Returns the created task's slug and id.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "workspace" => %{
            "type" => "string",
            "description" => "Context slug where the task will be created."
          },
          "title" => %{
            "type" => "string",
            "description" => "Task title (human-readable)."
          },
          "slug" => %{
            "type" => "string",
            "description" =>
              "URL-friendly kebab-case slug, unique per context. Auto-generated from the title when omitted."
          },
          "body" => %{
            "type" => "string",
            "description" => "Task description in Markdown (optional)."
          },
          "status" => %{
            "type" => "string",
            "description" =>
              "Board column: backlog, todo, in_progress, done, or cancelled (default: backlog).",
            "enum" => ["backlog", "todo", "in_progress", "done", "cancelled"]
          },
          "priority" => %{
            "type" => "string",
            "description" => "Priority level: low, medium, high, or urgent (optional).",
            "enum" => ["low", "medium", "high", "urgent"]
          },
          "due_date" => %{
            "type" => "string",
            "description" => "Due date in YYYY-MM-DD format (optional)."
          },
          "recurrence" => %{
            "type" => "string",
            "description" =>
              "Recurrence: none, daily, weekly, or monthly (default: none). Completing a recurring task auto-creates the next occurrence in backlog with the next due date.",
            "enum" => ["none", "daily", "weekly", "monthly"]
          },
          "checklist" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" =>
              "Subtask checklist (optional): list of item texts. Stored in meta; toggling done happens via the UI or dran_update_task meta."
          },
          "created_by" => %{
            "type" => "string",
            "description" =>
              "Who created this task, for provenance. Defaults to the authenticated identity (API key name or user email)."
          },
          "on_behalf_of" => %{
            "type" => "string",
            "description" => "Who an agent is acting on behalf of (optional)."
          }
        },
        "required" => ["workspace", "title"]
      }
    },
    %{
      "name" => "dran_update_task",
      "description" =>
        "Update a task by slug: status, priority, due_date, recurrence, title, body, checklist, or archived. Setting status to done/cancelled on a recurring task auto-clones the next occurrence. Goal/page links are managed with dran_create_relation / dran_delete_relation (source_type `task`). Returns the updated task.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "workspace" => %{
            "type" => "string",
            "description" => "Context slug containing the task."
          },
          "slug" => %{
            "type" => "string",
            "description" => "Task slug."
          },
          "title" => %{"type" => "string", "description" => "New title (optional)."},
          "body" => %{"type" => "string", "description" => "New body (optional)."},
          "status" => %{
            "type" => "string",
            "description" => "New board column (optional).",
            "enum" => ["backlog", "todo", "in_progress", "done", "cancelled"]
          },
          "priority" => %{
            "type" => "string",
            "description" => "New priority (optional).",
            "enum" => ["low", "medium", "high", "urgent"]
          },
          "due_date" => %{
            "type" => "string",
            "description" => "New due date YYYY-MM-DD, or empty string to clear (optional)."
          },
          "recurrence" => %{
            "type" => "string",
            "description" => "New recurrence (optional).",
            "enum" => ["none", "daily", "weekly", "monthly"]
          },
          "checklist" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Replaces the subtask checklist (optional)."
          },
          "archived" => %{
            "type" => "boolean",
            "description" =>
              "Archive (true) or unarchive (false) the task (optional). Archived tasks leave the board but keep their data."
          }
        },
        "required" => ["workspace", "slug"]
      }
    },
    %{
      "name" => "dran_list_tasks",
      "description" =>
        "List tasks in a context, optionally filtered by status. Returns id, slug, title, status, priority, due_date, recurrence per task. Read-only.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "workspace" => %{
            "type" => "string",
            "description" => "Context slug to list tasks from."
          },
          "status" => %{
            "type" => "string",
            "description" => "Filter by board column (optional).",
            "enum" => ["backlog", "todo", "in_progress", "done", "cancelled"]
          }
        },
        "required" => ["workspace"]
      }
    },
    %{
      "name" => "dran_lint_brain",
      "description" =>
        "Brain hygiene audit (read-only). Returns three categories: orphan pages (no inbound links, likely disconnected), stale pages (not updated in 90+ days, possibly outdated), and contested pages (conflicting knowledge flagged by the system). Use this during maintenance or cleanup to find pages needing attention. Does not modify anything.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "workspace" => %{
            "type" => "string",
            "description" => "Context slug to lint."
          }
        },
        "required" => ["workspace"]
      }
    },
    %{
      "name" => "dran_delete_page",
      "description" =>
        "Delete a page by slug. **This is irreversible** — cascading deletes remove all relations to/from the page and all page version history. There is no undo. Always confirm with the user before calling. Returns a confirmation with the deleted page's title and slug, or an error if not found.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "workspace" => %{
            "type" => "string",
            "description" => "Context slug containing the page."
          },
          "slug" => %{
            "type" => "string",
            "description" =>
              "Slug of the page to delete. All relations and version history for this page will be removed."
          }
        },
        "required" => ["workspace", "slug"]
      }
    },
    %{
      "name" => "dran_create_relation",
      "description" =>
        "Create a typed, directed relation from a source page to a target page. Relation types: `related` (generic link), `contradicts` (source disagrees with target), `supersedes` (source replaces/outdates target), `part_of` (source is a component of target), `embeds` (source embeds target — usually auto-created by `![[slug]]`). Returns an error if either slug is not found in the context. Duplicate relations on the same pair/type are idempotent.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "workspace" => %{
            "type" => "string",
            "description" => "Context slug containing both pages."
          },
          "source_slug" => %{
            "type" => "string",
            "description" => "Slug of the source page (the relation originates here)."
          },
          "target_slug" => %{
            "type" => "string",
            "description" => "Slug of the target page (the relation points here)."
          },
          "relation_type" => %{
            "type" => "string",
            "description" =>
              "Type of directed relation: 'related' (generic), 'contradicts' (source contradicts target), 'supersedes' (source replaces target), 'part_of' (source is part of target), 'embeds' (source embeds target). Defaults to 'related'.",
            "enum" => ["related", "contradicts", "supersedes", "part_of", "embeds"]
          }
        },
        "required" => ["workspace", "source_slug", "target_slug"]
      }
    },
    %{
      "name" => "dran_get_links",
      "description" =>
        "Graph exploration: get all inbound and outbound relations for a page. Returns two lists: outbound (pages this page links to, with relation type and target title/slug) and inbound (pages linking to this page, with source title/slug and relation type). Use this to understand a page's connections before editing or deleting. Returns an error if the slug is not found.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "workspace" => %{
            "type" => "string",
            "description" => "Context slug containing the page."
          },
          "slug" => %{
            "type" => "string",
            "description" => "Slug of the page whose relations to retrieve."
          }
        },
        "required" => ["workspace", "slug"]
      }
    },
    %{
      "name" => "dran_list_pages",
      "description" =>
        "Lightweight listing with filters. Returns metadata only (title, slug, type) — no body content. Use `type` to list a specific page type, `tag` to filter by tag, and `status` to filter todo-style notes by kanban status. For a full index overview, prefer the `home://{workspace}/index` resource instead. Use `dran_get_page` to read full content. Results are capped at `limit` (default 50, max 500).",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "workspace" => %{
            "type" => "string",
            "description" => "Context slug to list pages from."
          },
          "type" => %{
            "type" => "string",
            "description" => "Optional filter by page type: note, concept, entity, or reference.",
            "enum" => [
              "note",
              "concept",
              "entity",
              "reference"
            ]
          },
          "tag" => %{
            "type" => "string",
            "description" => "Optional filter: only pages with this tag."
          },
          "status" => %{
            "type" => "string",
            "description" =>
              "Optional filter for todo-style notes by kanban_status: backlog, todo, in_progress, done, or cancelled.",
            "enum" => ["backlog", "todo", "in_progress", "done", "cancelled"]
          },
          "limit" => %{
            "type" => "integer",
            "description" => "Maximum number of results (default 50, hard max 500)."
          },
          "offset" => %{
            "type" => "integer",
            "description" =>
              "Number of results to skip for pagination (default 0). Use with limit to paginate large lists."
          },
          "owner" => %{
            "type" => "string",
            "description" => "Optional filter: only pages whose `owner` matches this value."
          },
          "created_by" => %{
            "type" => "string",
            "description" =>
              "Optional filter: only pages whose `created_by` (provenance) matches this value."
          },
          "assignee" => %{
            "type" => "string",
            "description" =>
              "Optional filter for todos: only todos whose meta.assignee matches this value. Use the literal value 'none' to list unassigned todos (no assignee)."
          },
          "props" => %{
            "type" => "object",
            "description" =>
              "Filter by custom properties (meta.props). Matches pages where ALL given key-value pairs are present (AND logic). Example: {\"role\": \"sales\", \"tier\": \"vip\"}"
          }
        },
        "required" => ["workspace"]
      }
    },
    %{
      "name" => "dran_update_note",
      "description" =>
        "Update a note's kanban fields (kanban_status, priority, due_date, assignee), title, body, or tags. **Meta is MERGED, not replaced** — pass only the fields you want to change; existing meta keys (kanban_status, priority, due_date, assignee) are preserved. This is the key difference from `dran_update_page`, which replaces the entire meta object. Note that `tags` replaces the existing tag list entirely. Link the note to goals/projects separately via dran_create_relation. Returns the updated note's title, slug, and current kanban status.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "workspace" => %{
            "type" => "string",
            "description" => "Context slug containing the note."
          },
          "slug" => %{
            "type" => "string",
            "description" => "Slug of the note page to update."
          },
          "kanban_status" => %{
            "type" => "string",
            "description" =>
              "New kanban status: backlog, todo, in_progress, done, or cancelled (optional). Typical progression: backlog → todo → in_progress → done.",
            "enum" => ["backlog", "todo", "in_progress", "done", "cancelled"]
          },
          "priority" => %{
            "type" => "string",
            "description" => "New priority: low, medium, high, or urgent (optional).",
            "enum" => ["low", "medium", "high", "urgent"]
          },
          "due_date" => %{
            "type" => "string",
            "description" => "New due date in YYYY-MM-DD format (optional)."
          },
          "assignee" => %{
            "type" => "string",
            "description" =>
              "Reassign the note to a different actor (optional). Free-form string — e.g. 'alvaro', 'hermes', 'claude-code'."
          },
          "title" => %{
            "type" => "string",
            "description" => "New title (optional)."
          },
          "body" => %{
            "type" => "string",
            "description" => "New Markdown body (optional)."
          },
          "tags" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "New tags list (optional). Replaces existing tags entirely."
          },
          "owner" => %{
            "type" => "string",
            "description" => "New owner identity for the note (optional)."
          },
          "created_by" => %{
            "type" => "string",
            "description" =>
              "Override who created this note (optional, for provenance corrections)."
          },
          "on_behalf_of" => %{
            "type" => "string",
            "description" => "Set or clear who an agent is acting on behalf of (optional)."
          },
          "updated_by" => %{
            "type" => "string",
            "description" => "Who is updating the note, for provenance (defaults to 'agent')."
          }
        },
        "required" => ["workspace", "slug"]
      }
    },
    %{
      "name" => "dran_delete_relation",
      "description" =>
        "Delete relations between two pages. **This is irreversible.** If `relation_type` is provided, only relations of that type are deleted; if omitted, ALL relations between the two pages (both directions) are deleted. Use `dran_get_links` first to inspect existing relations before deleting. Returns the count of deleted relations.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "workspace" => %{
            "type" => "string",
            "description" => "Context slug containing both pages."
          },
          "source_slug" => %{
            "type" => "string",
            "description" => "Slug of the source page of the relation."
          },
          "target_slug" => %{
            "type" => "string",
            "description" => "Slug of the target page of the relation."
          },
          "relation_type" => %{
            "type" => "string",
            "description" =>
              "If provided, only delete relations of this type. If omitted, all relations between the two pages are deleted in both directions.",
            "enum" => ["related", "contradicts", "supersedes", "part_of", "embeds"]
          }
        },
        "required" => ["workspace", "source_slug", "target_slug"]
      }
    },
    %{
      "name" => "dran_get_stats",
      "description" =>
        "Context dashboard numbers: total page count, pages by type, todos by kanban status, orphan count, total relations, and broken-link count. Use this for dashboard overviews, weekly reviews, or to check the overall health of a context. Read-only.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "workspace" => %{
            "type" => "string",
            "description" => "Context slug to get statistics for."
          }
        },
        "required" => ["workspace"]
      }
    },
    %{
      "name" => "dran_rename_slug",
      "description" =>
        "Rename a page slug; auto-rewrites all `![[old-slug]]` embeds in other pages of the same context. Updates the page's slug in place; version history and relations are preserved. **Fails if `new_slug` already exists** in the context. Use this to fix a wrongly named page without deleting and recreating it.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "workspace" => %{
            "type" => "string",
            "description" => "Context slug containing the page."
          },
          "old_slug" => %{
            "type" => "string",
            "description" => "Current slug of the page to rename."
          },
          "new_slug" => %{
            "type" => "string",
            "description" =>
              "New kebab-case slug. Must not already exist in the context, and must differ from old_slug."
          }
        },
        "required" => ["workspace", "old_slug", "new_slug"]
      }
    },
    %{
      "name" => "dran_reaugment_page",
      "description" =>
        "Re-run the augmentation pipeline (summary/tags/embedding/relations) for a page. Use after major edits or if augmentation previously failed. Clears the stored `embedding_hash` so the pipeline treats the page as stale, then schedules async augmentation.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "workspace" => %{
            "type" => "string",
            "description" => "Context slug containing the page."
          },
          "slug" => %{
            "type" => "string",
            "description" => "Slug of the page to reaugment."
          }
        },
        "required" => ["workspace", "slug"]
      }
    },
    %{
      "name" => "dran_generate_cluster_summaries",
      "description" =>
        "Generate or regenerate LLM-powered summaries for all knowledge clusters detected via Label Propagation. Requires inference to be configured. Clusters are clusters of related pages grouped by relation types (part_of, embeds, related, supersedes). Each cluster gets a 2-3 sentence summary that captures its main theme. Returns the count of summaries generated.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "workspace" => %{
            "type" => "string",
            "description" => "Context slug to generate cluster summaries for."
          }
        },
        "required" => ["workspace"]
      }
    },
    %{
      "name" => "dran_start_agent",
      "description" =>
        "Start an autonomous agent session and return immediately. Returns a session_id and track_url — poll `dran_get_agent_session` with that session_id to check progress, steps, and summary. The agent runs asynchronously in the background. Choose the agent_type that matches your goal: 'curator' detects duplicate/conflicting pages via embeddings and writes a report; 'link_gardener' proposes relations for orphan pages.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "agent_type" => %{
            "type" => "string",
            "enum" => ["curator", "link_gardener", "graph_rag"],
            "description" =>
              "Type of agent to run. 'curator' = detect duplicates/conflicts by embeddings and write a report. 'link_gardener' = propose relations for orphan pages. 'graph_rag' = answer questions using GraphRAG (local/global/drift search over the knowledge graph)."
          },
          "workspace" => %{
            "type" => "string",
            "description" => "Context slug where the agent will create pages."
          },
          "input" => %{
            "type" => "string",
            "description" =>
              "Agent input. For curator/link_gardener: typically the context focus or instructions. For graph_rag: the question to answer."
          },
          "opts" => %{
            "type" => "object",
            "description" =>
              "Optional agent configuration options (e.g. max pages, tags). Passed through to the agent."
          }
        },
        "required" => ["agent_type", "workspace", "input"]
      }
    },
    %{
      "name" => "dran_get_agent_session",
      "description" =>
        "Poll an autonomous agent session for status, summary, and step-by-step progress. Returns the session's type, input, status (pending/running/done/failed), summary, pages_created count, and an ordered list of steps with tool name and result status. Poll periodically until status is 'done' or 'failed'. Returns an error if the session_id is invalid or not found.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "session_id" => %{
            "type" => "string",
            "description" => "UUID of the agent session to poll (returned by dran_start_agent)."
          }
        },
        "required" => ["session_id"]
      }
    }
  ]

  @resources [
    %{
      "uri" => "page://{workspace}/{slug}",
      "name" => "Page content",
      "description" => "Full page content as markdown",
      "mimeType" => "text/markdown"
    },
    %{
      "uri" => "goal://{workspace}/{slug}",
      "name" => "Goal detail",
      "description" => "Goal detail with linked todo notes",
      "mimeType" => "application/json"
    },
    %{
      "uri" => "home://{workspace}/index",
      "name" => "Wiki index",
      "description" => "All pages in a context (slug + title + type)",
      "mimeType" => "application/json"
    }
  ]

  @prompts [
    %{
      "name" => "brainstorm",
      "description" => "Generate ideas around a topic.",
      "arguments" => [
        %{"name" => "topic", "description" => "The topic to brainstorm", "required" => true},
        %{"name" => "workspace", "description" => "Context slug", "required" => true}
      ]
    },
    %{
      "name" => "goal_review",
      "description" => "Review a goal's status, todos, and plans.",
      "arguments" => [
        %{"name" => "goal_slug", "description" => "Goal slug", "required" => true},
        %{"name" => "workspace", "description" => "Context slug", "required" => true}
      ]
    }
  ]

  # ── Public API for controller ──────────────────────────────────────────────

  @doc "Process a JSON-RPC message and return the response map"
  def process_message(msg, opts \\ []) do
    user = Keyword.get(opts, :user)

    # Add user context to all tool calls so operations are scoped to the
    # user's assigned/requested context.
    msg = inject_user_context(msg, user)

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

        cond do
          # SEC-002: write enforcement — per-workspace via access_levels (API keys)
          write_tool?(tool_name) and not can_write?(user, args) ->
            %{
              "jsonrpc" => "2.0",
              "id" => id,
              "error" => %{
                "code" => -32602,
                "message" => "API key is read-only for this workspace"
              }
            }

          true ->
            # SEC-001: validate that the requested context is accessible by the user
            case validate_tool_context_access(args, user) do
              :ok ->
                result = execute_tool(tool_name, args, user)

                %{
                  "jsonrpc" => "2.0",
                  "id" => id,
                  "result" => %{
                    "content" => [%{"type" => "text", "text" => result}]
                  }
                }

              {:error, :forbidden} ->
                %{
                  "jsonrpc" => "2.0",
                  "id" => id,
                  "error" => %{
                    "code" => -32602,
                    "message" => "Access to context denied"
                  }
                }
            end
        end

      %{"jsonrpc" => "2.0", "method" => "resources/list", "id" => id} ->
        %{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => %{"resources" => @resources}
        }

      %{"jsonrpc" => "2.0", "method" => "resources/read", "id" => id, "params" => params} ->
        uri = params["uri"]

        # SEC-001: validate context access for resources too
        case validate_resource_context_access(uri, user) do
          :ok ->
            content = read_resource(uri)

            %{
              "jsonrpc" => "2.0",
              "id" => id,
              "result" => %{
                "contents" => [%{"uri" => uri, "mimeType" => "text/markdown", "text" => content}]
              }
            }

          {:error, :forbidden} ->
            %{
              "jsonrpc" => "2.0",
              "id" => id,
              "error" => %{
                "code" => -32602,
                "message" => "Access to context denied"
              }
            }
        end

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

  # ── Authorization (single policy: DranWeb.ResourceAuthorization) ───────────
  #
  # SEC-001 (read access) and SEC-002 (write access) both route through
  # authorize/3. The user shapes accepted there mirror exactly what the
  # API auth pipelines produce; `nil` stays fail-open for tests.

  defp can_write?(user, args) do
    case workspace_from_args(args) do
      nil ->
        # No workspace in args — nothing to enforce here; the context access
        # check below rejects inaccessible workspaces anyway.
        true

      workspace ->
        ResourceAuthorization.authorize(user, :write, workspace) == :ok
    end
  end

  defp validate_tool_context_access(args, user) when is_map(args) do
    case workspace_from_args(args) do
      nil -> :ok
      workspace -> ResourceAuthorization.authorize(user, :read, workspace)
    end
  end

  defp validate_tool_context_access(_, _), do: :ok

  defp workspace_from_args(args), do: args["workspace"]

  # SEC-001: Validate context access for resource URIs like page://context/slug
  defp validate_resource_context_access(uri, user) when is_binary(uri) do
    case String.split(uri, "://", parts: 2) do
      [_scheme, rest] ->
        case String.split(rest, "/", parts: 2) do
          [workspace_slug, _path] ->
            ResourceAuthorization.authorize(user, :read, workspace_slug)

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp validate_resource_context_access(_, _), do: :ok

  # SEC-002: Read-only API key enforcement
  @write_tools MapSet.new([
                 "dran_create_page",
                 "dran_update_page",
                 "dran_delete_page",
                 "dran_create_note",
                 "dran_update_note",
                 "dran_create_goal",
                 "dran_create_task",
                 "dran_update_task",
                 "dran_create_relation",
                 "dran_delete_relation",
                 "dran_rename_slug",
                 "dran_reaugment_page",
                 "dran_start_agent",
                 "dran_generate_cluster_summaries"
               ])

  defp write_tool?(name) when is_binary(name), do: MapSet.member?(@write_tools, name)
  defp write_tool?(_), do: false

  defp inject_user_context(msg, nil), do: msg

  defp inject_user_context(
         %{"jsonrpc" => "2.0", "method" => "tools/call", "params" => params} = msg,
         user
       )
       when is_map(params) do
    args = params["arguments"] || %{}

    if Map.has_key?(args, "workspace") do
      msg
    else
      case get_default_context_for_user(user) do
        nil ->
          msg

        default_context ->
          put_in(msg, ["params", "arguments", "workspace"], default_context)
      end
    end
  end

  defp inject_user_context(msg, _user), do: msg

  defp get_default_context_for_user(%{is_owner: true}), do: nil
  defp get_default_context_for_user(%{workspaces: :all}), do: nil

  defp get_default_context_for_user(%{workspaces: [first | _]}), do: first.slug

  defp get_default_context_for_user(%{contexts: :all}), do: nil
  defp get_default_context_for_user(%{contexts: [first | _]}), do: first.slug
  defp get_default_context_for_user(_), do: nil

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

  defp execute_tool(
         "dran_search",
         %{"query" => query, "workspace" => workspace_slug} = args,
         _user
       ) do
    context = workspace_cache_get(workspace_slug)

    if context do
      opts = [workspace_id: context.id]
      opts = if args["type"], do: Keyword.put(opts, :type, args["type"]), else: opts
      opts = if args["strategy"], do: Keyword.put(opts, :strategy, args["strategy"]), else: opts
      opts = if args["limit"], do: Keyword.put(opts, :limit, min(args["limit"], 100)), else: opts
      opts = if args["offset"], do: Keyword.put(opts, :offset, args["offset"]), else: opts
      opts = if args["props"], do: Keyword.put(opts, :props, args["props"]), else: opts

      case Knowledge.search(query, opts) do
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
      "Error: context '#{workspace_slug}' not found"
    end
  end

  defp execute_tool(
         "dran_create_page",
         %{"workspace" => workspace_slug, "page_type" => page_type} = args,
         user
       ) do
    context = workspace_cache_get(workspace_slug)

    cond do
      is_nil(context) ->
        "Error: context '#{workspace_slug}' not found"

      page_type not in PageTypes.types() ->
        "Error: page type '#{page_type}' is not a valid page type — use dran_create_goal or dran_create_note for goals and todo-style notes"

      true ->
        attrs =
          %{
            workspace_id: context.id,
            title: Map.get(args, "title"),
            slug: Map.get(args, "slug"),
            page_type: page_type,
            body: Map.get(args, "body", ""),
            tags: Map.get(args, "tags", []),
            summary: Map.get(args, "summary"),
            meta: Map.get(args, "meta", %{}),
            # server-side attribution — not client-settable
            created_by: Auth.resolve_created_by(user)
          }
          |> maybe_put(:on_behalf_of, args["on_behalf_of"])

        case Knowledge.create_page(attrs) do
          {:ok, page} ->
            "Created page: #{page.title} (#{page.slug})"

          {:error, :page_type_disabled} ->
            "Error: page type '#{attrs[:page_type]}' is disabled in context '#{workspace_slug}'"

          {:error, changeset} ->
            "Error: #{format_changeset_errors(changeset)}"
        end
    end
  end

  defp execute_tool(
         "dran_update_page",
         %{"workspace" => workspace_slug, "slug" => slug} = args,
         user
       ) do
    context = workspace_cache_get(workspace_slug)

    if context do
      case Knowledge.get_page_by_slug(slug, context.id) do
        nil ->
          "Error: page '#{slug}' not found in context '#{workspace_slug}'"

        page ->
          # owner/created_by are NOT client-settable — server-side attribution
          attrs =
            Map.take(args, [
              "title",
              "body",
              "tags",
              "meta",
              "summary",
              "archived",
              "on_behalf_of",
              "kb_confidence",
              "kb_source_url",
              "kb_contested"
            ])
            |> Map.put("updated_by", Auth.resolve_created_by(user))

          case Knowledge.update_page(page, attrs) do
            {:ok, updated} ->
              "Updated page: #{updated.title} (v#{updated.version})"

            {:error, changeset} ->
              "Error: #{format_changeset_errors(changeset)}"
          end
      end
    else
      "Error: context '#{workspace_slug}' not found"
    end
  end

  defp execute_tool("dran_get_page", %{"workspace" => workspace_slug, "slug" => slug}, _user) do
    context = workspace_cache_get(workspace_slug)

    if context do
      case Knowledge.get_page_by_slug(slug, context.id) do
        nil ->
          "Error: page '#{slug}' not found"

        page ->
          "# #{page.title}\n\n#{page.body}\n\n---\nType: #{page.page_type} | Tags: #{Enum.join(page.tags, ", ")} | Version: #{page.version}"
      end
    else
      "Error: context '#{workspace_slug}' not found"
    end
  end

  defp execute_tool(
         "dran_create_task",
         %{"workspace" => workspace_slug, "title" => title} = args,
         user
       ) do
    context = workspace_cache_get(workspace_slug)

    if context do
      meta =
        case args["checklist"] do
          nil ->
            %{}

          items when is_list(items) ->
            %{"checklist" => Enum.map(items, &%{"text" => &1, "done" => false})}

          _ ->
            %{}
        end

      attrs =
        %{
          "workspace_id" => context.id,
          "title" => title,
          "body" => Map.get(args, "body", ""),
          "status" => Map.get(args, "status", "backlog"),
          "recurrence" => Map.get(args, "recurrence", "none"),
          "meta" => meta,
          # server-side attribution — not client-settable
          "created_by" => Auth.resolve_created_by(user),
          "creator_actor_id" => Auth.resolve_acting_actor(user)
        }
        |> maybe_put("slug", args["slug"])
        |> maybe_put("priority", args["priority"])
        |> maybe_put_str("due_date", args["due_date"])
        |> maybe_put("on_behalf_of", args["on_behalf_of"])
        |> maybe_put_assignee_actor(args["assignee"])

      case Dran.Tasks.create_task(attrs) do
        {:ok, task} ->
          "Created task: #{task.title} (#{task.slug}, id: #{task.id}) — status: #{task.status}"

        {:error, changeset} ->
          "Error: #{format_changeset_errors(changeset)}"
      end
    else
      "Error: context '#{workspace_slug}' not found"
    end
  end

  defp execute_tool(
         "dran_update_task",
         %{"workspace" => workspace_slug, "slug" => slug} = args,
         user
       ) do
    context = workspace_cache_get(workspace_slug)

    if context do
      case Dran.Tasks.get_task_by_slug(slug, context.id) do
        nil ->
          "Error: task '#{slug}' not found"

        task ->
          attrs = %{"updated_by" => Auth.resolve_created_by(user)}
          attrs = if args["title"], do: Map.put(attrs, "title", args["title"]), else: attrs
          attrs = if args["body"], do: Map.put(attrs, "body", args["body"]), else: attrs

          attrs =
            if is_boolean(args["archived"]),
              do: Map.put(attrs, "archived", args["archived"]),
              else: attrs

          attrs = maybe_put(attrs, "status", args["status"])
          attrs = maybe_put(attrs, "priority", args["priority"])
          attrs = maybe_put_str(attrs, "due_date", args["due_date"])
          attrs = maybe_put(attrs, "recurrence", args["recurrence"])

          attrs =
            case args["checklist"] do
              nil ->
                attrs

              items when is_list(items) ->
                Map.put(
                  attrs,
                  "meta",
                  Map.merge(task.meta || %{}, %{
                    "checklist" => Enum.map(items, &%{"text" => &1, "done" => false})
                  })
                )

              _ ->
                attrs
            end

          case Dran.Tasks.update_task(task, attrs) do
            {:ok, updated} ->
              "Updated task: #{updated.title} (#{updated.slug}) — status: #{updated.status}"

            {:error, changeset} ->
              "Error: #{format_changeset_errors(changeset)}"
          end
      end
    else
      "Error: context '#{workspace_slug}' not found"
    end
  end

  defp execute_tool("dran_list_tasks", %{"workspace" => workspace_slug} = args, _user) do
    context = workspace_cache_get(workspace_slug)

    if context do
      opts = [workspace_id: context.id, limit: 200]

      opts =
        if args["status"] do
          Keyword.put(opts, :status, args["status"])
        else
          opts
        end

      tasks = Dran.Tasks.list_tasks(opts)

      if tasks == [] do
        "No tasks found in context '#{workspace_slug}'."
      else
        lines =
          for task <- tasks do
            parts = [
              "- #{task.title} (#{task.slug}, id: #{task.id})",
              "status: #{task.status}",
              task.priority && "priority: #{task.priority}",
              task.due_date && "due: #{task.due_date}",
              task.recurrence != "none" && "recurrence: #{task.recurrence}"
            ]

            Enum.reject(parts, &is_nil(&1)) |> Enum.join(" | ")
          end

        "Tasks in '#{workspace_slug}' (#{length(tasks)}):\n" <> Enum.join(lines, "\n")
      end
    else
      "Error: context '#{workspace_slug}' not found"
    end
  end

  defp execute_tool(
         "dran_create_note",
         %{"workspace" => workspace_slug, "title" => title, "slug" => slug} = args,
         user
       ) do
    context = workspace_cache_get(workspace_slug)

    if context do
      meta =
        %{}
        |> Map.put("kind", Map.get(args, "kind", "journal"))
        |> maybe_put_meta("due_date", args["due_date"])

      attrs =
        %{
          workspace_id: context.id,
          title: title,
          slug: slug,
          page_type: "note",
          body: Map.get(args, "body", ""),
          meta: meta,
          # server-side attribution — not client-settable
          created_by: Auth.resolve_created_by(user)
        }
        |> maybe_put(:on_behalf_of, args["on_behalf_of"])

      case Knowledge.create_page(attrs) do
        {:ok, note} ->
          status = Map.get(meta, "kanban_status")
          "Created note: #{note.title} (#{note.slug}) — status: #{status}"

        {:error, :page_type_disabled} ->
          "Error: page type 'note' is disabled in context '#{workspace_slug}'"

        {:error, changeset} ->
          "Error: #{format_changeset_errors(changeset)}"
      end
    else
      "Error: context '#{workspace_slug}' not found"
    end
  end

  defp execute_tool(
         "dran_create_goal",
         %{"workspace" => workspace_slug, "title" => title} = args,
         user
       ) do
    context = workspace_cache_get(workspace_slug)

    if context do
      slug = Map.get(args, "slug") || Dran.Slug.generate(title, context.id, "goal")

      attrs =
        %{
          workspace_id: context.id,
          title: title,
          slug: slug,
          description: Map.get(args, "description"),
          body: Map.get(args, "body", ""),
          kind: args["kind"],
          health: args["health"],
          status: Map.get(args, "status", "active"),
          metric: args["metric"],
          target_value: args["target_value"],
          current_value: args["current_value"],
          unit: args["unit"],
          start_date: parse_date(args["start_date"]),
          target_date: parse_date(args["target_date"]),
          team: args["team"] || [],
          # server-side attribution — not client-settable
          created_by: Auth.resolve_created_by(user)
        }

      case Goals.create_goal(attrs) do
        {:ok, goal} ->
          "Created goal: #{goal.title} (#{goal.slug}) — status: #{goal.status}"

        {:error, changeset} ->
          "Error: #{format_changeset_errors(changeset)}"
      end
    else
      "Error: context '#{workspace_slug}' not found"
    end
  end

  defp execute_tool("dran_lint_brain", %{"workspace" => workspace_slug}, _user) do
    context = workspace_cache_get(workspace_slug)

    if context do
      report = Knowledge.lint(context.id)

      """
      # Lint Report for '#{workspace_slug}'

      ## Orphan pages (no inbound links): #{length(report.orphans)}
      #{format_page_list(report.orphans)}

      ## Stale pages (>90 days): #{length(report.stale)}
      #{format_page_list(report.stale)}

      ## Contested pages: #{length(report.contested)}
      #{format_page_list(report.contested)}
      """
    else
      "Error: context '#{workspace_slug}' not found"
    end
  end

  defp execute_tool("dran_delete_page", %{"workspace" => workspace_slug, "slug" => slug}, _user) do
    context = workspace_cache_get(workspace_slug)

    if context do
      case Knowledge.get_page_by_slug(slug, context.id) do
        nil ->
          "Error: page '#{slug}' not found in context '#{workspace_slug}'"

        page ->
          case Knowledge.delete_page(page) do
            {:ok, _} ->
              "Deleted page: #{page.title} (#{page.slug})"

            {:error, _} ->
              "Error: could not delete page '#{slug}'"
          end
      end
    else
      "Error: context '#{workspace_slug}' not found"
    end
  end

  defp execute_tool(
         "dran_create_relation",
         %{
           "workspace" => workspace_slug,
           "source_slug" => source_slug,
           "target_slug" => target_slug
         } =
           args,
         _user
       ) do
    context = workspace_cache_get(workspace_slug)

    if context do
      relation_type = Map.get(args, "relation_type", "related")

      # P-02: batch lookup both pages in one query
      pages = Knowledge.get_pages_by_slugs([source_slug, target_slug], context.id)

      case {Map.get(pages, source_slug), Map.get(pages, target_slug)} do
        {nil, _} ->
          "Error: source page '#{source_slug}' not found"

        {_, nil} ->
          "Error: target page '#{target_slug}' not found"

        {_source_type, _target_type} ->
          case Knowledge.create_relation_by_slugs(
                 source_slug,
                 target_slug,
                 relation_type,
                 context.id
               ) do
            {:ok, _relation} ->
              "Created relation: #{source_slug} --#{relation_type}--> #{target_slug}"

            {:error, :source_not_found} ->
              "Error: source page '#{source_slug}' not found"

            {:error, :target_not_found} ->
              "Error: target page '#{target_slug}' not found"

            {:error, changeset} ->
              "Error: #{format_changeset_errors(changeset)}"
          end
      end
    else
      "Error: context '#{workspace_slug}' not found"
    end
  end

  defp execute_tool("dran_get_links", %{"workspace" => workspace_slug, "slug" => slug}, _user) do
    context = workspace_cache_get(workspace_slug)

    if context do
      case Knowledge.get_page_by_slug(slug, context.id) do
        nil ->
          "Error: page '#{slug}' not found"

        page ->
          relations = Knowledge.list_relations_for_page(page.id)

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
      "Error: context '#{workspace_slug}' not found"
    end
  end

  defp execute_tool("dran_list_pages", %{"workspace" => workspace_slug} = args, _user) do
    context = workspace_cache_get(workspace_slug)

    if context do
      limit = min(Map.get(args, "limit", 50), 500)
      offset = Map.get(args, "offset", 0)

      opts = [workspace_id: context.id, context: context, limit: limit, offset: offset]
      opts = if args["type"], do: Keyword.put(opts, :type, args["type"]), else: opts
      opts = if args["tag"], do: Keyword.put(opts, :tag, args["tag"]), else: opts
      opts = if args["status"], do: Keyword.put(opts, :status, args["status"]), else: opts

      opts = if args["owner"], do: Keyword.put(opts, :owner, args["owner"]), else: opts

      opts =
        if args["created_by"],
          do: Keyword.put(opts, :created_by, args["created_by"]),
          else: opts

      opts =
        if args["assignee"],
          do: Keyword.put(opts, :assignee, args["assignee"]),
          else: opts

      opts = if args["props"], do: Keyword.put(opts, :props, args["props"]), else: opts

      pages = Knowledge.list_pages(opts)

      lines =
        if args["type"] && not Knowledge.page_type_enabled?(context, args["type"]) do
          ["Error: page type '#{args["type"]}' is disabled in context '#{workspace_slug}'"]
        else
          Enum.map(pages, fn page ->
            "- **#{page.title}** (`#{page.slug}`, type: #{page.page_type})"
          end)
        end

      "Found #{length(pages)} pages:\n\n#{Enum.join(lines, "\n")}"
    else
      "Error: context '#{workspace_slug}' not found"
    end
  end

  defp execute_tool(
         "dran_update_note",
         %{"workspace" => workspace_slug, "slug" => slug} = args,
         user
       ) do
    context = workspace_cache_get(workspace_slug)

    if context do
      case Knowledge.get_page_by_slug(slug, context.id) do
        nil ->
          "Error: note '#{slug}' not found"

        note ->
          # Merge meta: start with existing, overlay changes
          existing_meta = note.meta || %{}

          new_meta =
            existing_meta
            |> maybe_put_meta("kanban_status", args["kanban_status"])
            |> maybe_put_meta("priority", args["priority"])
            |> maybe_put_meta("due_date", args["due_date"])
            |> maybe_put_meta("assignee", args["assignee"])

          attrs = %{"meta" => new_meta}
          attrs = Map.put(attrs, "updated_by", Auth.resolve_created_by(user))
          attrs = if args["title"], do: Map.put(attrs, "title", args["title"]), else: attrs
          attrs = if args["body"], do: Map.put(attrs, "body", args["body"]), else: attrs
          attrs = if args["tags"], do: Map.put(attrs, "tags", args["tags"]), else: attrs

          # owner/created_by NOT client-settable; on_behalf_of stays informative
          attrs =
            attrs
            |> maybe_put("on_behalf_of", args["on_behalf_of"])

          case Knowledge.update_page(note, attrs) do
            {:ok, updated} ->
              status = get_in(updated.meta, ["kanban_status"]) || "unknown"
              "Updated note: #{updated.title} (#{updated.slug}) — status: #{status}"

            {:error, changeset} ->
              "Error: #{format_changeset_errors(changeset)}"
          end
      end
    else
      "Error: context '#{workspace_slug}' not found"
    end
  end

  defp execute_tool(
         "dran_delete_relation",
         %{
           "workspace" => workspace_slug,
           "source_slug" => source_slug,
           "target_slug" => target_slug
         } =
           args,
         _user
       ) do
    context = workspace_cache_get(workspace_slug)

    if context do
      relation_type = Map.get(args, "relation_type")

      # P-02: batch lookup both pages in one query
      pages = Knowledge.get_pages_by_slugs([source_slug, target_slug], context.id)

      case {Map.get(pages, source_slug), Map.get(pages, target_slug)} do
        {nil, _} ->
          "Error: source page '#{source_slug}' not found"

        {_, nil} ->
          "Error: target page '#{target_slug}' not found"

        {_source_type, _target_type} ->
          case Knowledge.delete_relation_by_slugs(
                 source_slug,
                 target_slug,
                 relation_type,
                 context.id
               ) do
            {:error, :source_not_found} ->
              "Error: source page '#{source_slug}' not found"

            {:error, :target_not_found} ->
              "Error: target page '#{target_slug}' not found"

            {count, []} ->
              "Deleted #{count} relation(s) between '#{source_slug}' and '#{target_slug}'"

            {count, errors} ->
              "Deleted #{count} relation(s), but encountered errors: #{Enum.join(errors, ", ")}"
          end
      end
    else
      "Error: context '#{workspace_slug}' not found"
    end
  end

  defp execute_tool("dran_get_stats", %{"workspace" => workspace_slug}, _user) do
    context = workspace_cache_get(workspace_slug)

    if context do
      s = Knowledge.stats(context.id)

      by_type =
        s.by_type
        |> Enum.map(fn {type, count} -> "- #{type}: #{count}" end)
        |> Enum.join("\n")

      todos_by_status =
        s.todos_by_status
        |> Enum.map(fn {status, count} -> "- #{status}: #{count}" end)
        |> Enum.join("\n")

      """
      # Stats for '#{workspace_slug}'

      Total pages: #{s.total_pages}
      Total relations: #{s.total_relations}
      Orphan pages: #{s.orphan_count}

      ## Pages by type
      #{by_type}

      ## Todos by status
      #{todos_by_status}
      """
    else
      "Error: context '#{workspace_slug}' not found"
    end
  end

  defp execute_tool(
         "dran_rename_slug",
         %{"workspace" => workspace_slug, "old_slug" => old_slug, "new_slug" => new_slug},
         _user
       ) do
    context = workspace_cache_get(workspace_slug)

    if context do
      if old_slug == new_slug do
        "Error: old_slug and new_slug are the same"
      else
        # P-02: batch lookup both slugs in one query
        pages = Knowledge.get_pages_by_slugs([old_slug, new_slug], context.id)

        case {Map.get(pages, old_slug), Map.get(pages, new_slug)} do
          {nil, _} ->
            "Error: page '#{old_slug}' not found"

          {_, existing} when not is_nil(existing) ->
            "Error: a page with slug '#{new_slug}' already exists"

          {_page_type, nil} ->
            # Knowledge.rename_slug updates the page's slug in place and rewrites
            # all ![[old-slug]] embeds in other pages of the same context.
            Knowledge.rename_slug(Knowledge.get_page_by_slug(old_slug, context.id), new_slug)

            "Renamed '#{old_slug}' → '#{new_slug}'. Updated ![[#{old_slug}]] references in this context."
        end
      end
    else
      "Error: context '#{workspace_slug}' not found"
    end
  end

  defp execute_tool(
         "dran_start_agent",
         %{"agent_type" => agent_type, "workspace" => workspace_slug, "input" => input} = args,
         _user
       ) do
    context = workspace_cache_get(workspace_slug)

    if context do
      opts = Map.get(args, "opts", [])

      case start_agent_by_type(agent_type, input, context.id, opts) do
        {:ok, session} ->
          """
          Started #{agent_type} agent session.

          - session_id: #{session.id}
          - status: #{session.status}
          - track_url: /agents/#{agent_type}/#{session.id}

          Poll `dran_get_agent_session` with session_id for updates.
          """

        {:error, reason} ->
          "Error: failed to start agent: #{inspect(reason)}"
      end
    else
      "Error: context '#{workspace_slug}' not found"
    end
  end

  defp execute_tool("dran_get_agent_session", %{"session_id" => session_id}, _user) do
    case Ecto.UUID.cast(session_id) do
      {:ok, id} ->
        # P-04: preload steps in one query instead of N+1
        case Repo.get(Agent.Session, id) |> Repo.preload(:steps) do
          nil ->
            "Error: session not found"

          session ->
            steps = Enum.sort_by(session.steps, & &1.step_number)

            render_session(session, steps)
        end

      :error ->
        "Error: invalid session_id"
    end
  end

  defp execute_tool(
         "dran_reaugment_page",
         %{"workspace" => workspace_slug, "slug" => slug},
         _user
       ) do
    context = workspace_cache_get(workspace_slug)

    if context do
      case Knowledge.get_page_by_slug(slug, context.id) do
        nil ->
          "Error: page '#{slug}' not found in context '#{workspace_slug}'"

        page ->
          # Clear embedding_hash so the augmenter treats the page as stale,
          # then schedule async augmentation (summary/tags/embedding/relations).
          Ecto.Changeset.change(page, embedding_hash: nil) |> Repo.update!()
          Dran.PageAugmenter.schedule(page)
          "Reaugmentation scheduled for '#{slug}'"
      end
    else
      "Error: context '#{workspace_slug}' not found"
    end
  end

  defp execute_tool("dran_generate_cluster_summaries", %{"workspace" => workspace_slug}, _user) do
    context = workspace_cache_get(workspace_slug)

    if context do
      case Dran.Graph.ClusterSummaries.generate_all(context.id) do
        :ok ->
          summaries = Dran.Graph.ClusterSummaries.list_summaries(context.id)
          "Generated #{length(summaries)} cluster summaries for context '#{workspace_slug}'"

        {:error, reason} ->
          "Error generating cluster summaries: #{inspect(reason)}"
      end
    else
      "Error: context '#{workspace_slug}' not found"
    end
  end

  defp execute_tool(tool_name, _args, _user), do: "Error: unknown tool '#{tool_name}'"

  # ── Agent helpers ─────────────────────────────────────────────────────────

  defp start_agent_by_type("link_gardener", input, workspace_id, opts),
    do: Agent.LinkGardener.run(input, workspace_id, opts)

  defp start_agent_by_type("curator", input, workspace_id, opts),
    do: Agent.Curator.run(input, workspace_id, opts)

  defp start_agent_by_type("graph_rag", input, workspace_id, opts),
    do: Agent.GraphRag.run(input, workspace_id, opts)

  defp start_agent_by_type(_type, _input, _workspace_id, _opts),
    do: {:error, :unknown_agent_type}

  defp render_session(session, steps) do
    steps_text =
      Enum.map(steps, fn step ->
        "- Step #{step.step_number}: #{step.tool_name} → #{Map.get(step.tool_result || %{}, "status", "pending")}"
      end)
      |> Enum.join("\n")

    """
    # Agent session

    - type: #{session.agent_type}
    - input: #{session.input}
    - status: #{session.status}
    - summary: #{session.summary || "(pending)"}
    - pages_created: #{session.pages_created}
    - steps_count: #{session.steps_count}

    ## Steps

    #{steps_text}
    """
  end

  # ── Resource reading ──────────────────────────────────────────────────────

  defp read_resource("page://" <> rest) do
    [workspace_slug, slug] = String.split(rest, "/", parts: 2)
    context = workspace_cache_get(workspace_slug)

    if context do
      case Knowledge.get_page_by_slug(slug, context.id) do
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
    [workspace_slug, slug] = String.split(rest, "/", parts: 2)
    context = workspace_cache_get(workspace_slug)

    if context do
      case Goals.get_goal_by_slug(slug, context.id) do
        nil ->
          "Error: goal not found"

        goal ->
          # Find todo-kind notes linked to this goal via part_of relations
          import Ecto.Query

          linked_page_ids =
            from(r in Dran.Relation,
              where:
                r.target_id == ^goal.id and
                  r.target_type == "goal" and
                  r.relation_type == "part_of",
              select: r.source_id
            )
            |> Repo.all()

          todo_notes =
            if linked_page_ids == [] do
              []
            else
              from(p in Dran.Page,
                where:
                  p.workspace_id == ^context.id and
                    p.id in ^linked_page_ids and
                    p.page_type == "note",
                limit: 500
              )
              |> Repo.all()
              |> Enum.filter(fn p -> get_in(p.meta, ["kind"]) == "todo" end)
            end

          Jason.encode!(%{
            goal: %{title: goal.title, slug: goal.slug, body: goal.body},
            todos:
              Enum.map(
                todo_notes,
                &%{title: &1.title, slug: &1.slug, status: get_in(&1.meta, ["kanban_status"])}
              ),
            plans: []
          })
      end
    else
      "Error: context not found"
    end
  end

  defp read_resource("home://" <> rest) do
    [workspace_slug, "index"] = String.split(rest, "/", parts: 2)
    context = workspace_cache_get(workspace_slug)

    if context do
      # P-05: cap at 1,000 pages to avoid loading entire brain into memory
      pages = Knowledge.list_pages(workspace_id: context.id, context: context, limit: 1_000)

      lines =
        Enum.map(pages, fn page ->
          "- `#{page.slug}` — #{page.title} (#{page.page_type})"
        end)

      total_note =
        if length(pages) == 1_000 do
          "\n\n---\n_Note: showing first 1,000 pages. Use dran_search or dran_list_pages with filters for more targeted results._"
        else
          ""
        end

      Enum.join(lines, "\n") <> total_note
    else
      "Error: context not found"
    end
  end

  defp read_resource(_uri) do
    "Error: unknown resource URI format"
  end

  # ── Prompts ─────────────────────────────────────────────────────────────────

  defp get_prompt("brainstorm", %{"topic" => topic, "workspace" => context}) do
    [
      %{
        "role" => "user",
        "content" => %{
          "type" => "text",
          "text" => """
          Brainstorm ideas around: #{topic}

          Generate 5-10 ideas as pages in context '#{context}'.
          Use page_type 'note' with meta.kind 'idea' and interlink them with dran_create_relation where relevant.
          """
        }
      }
    ]
  end

  defp get_prompt("goal_review", %{"goal_slug" => slug, "workspace" => context}) do
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

  # Like maybe_put, but also skips empty strings (lets callers clear a value
  # with "" for meta-style keys while ignoring absent ones).
  defp maybe_put_str(map, _key, nil), do: map
  defp maybe_put_str(map, _key, ""), do: map
  defp maybe_put_str(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_meta(map, _key, nil), do: map
  defp maybe_put_meta(map, _key, ""), do: map
  defp maybe_put_meta(map, key, value), do: Map.put(map, key, value)

  # Resolve an assignee by actor name ("coder", "alvaro") to assignee_actor_id.
  # Unknown names are ignored (the task is created unassigned) — same lenient
  # contract as the other optional args.
  defp maybe_put_assignee_actor(map, name) when is_binary(name) and name != "" do
    case Dran.Actors.get_actor_by_name(String.trim(name)) do
      %Dran.Actors.Actor{id: id} -> Map.put(map, "assignee_actor_id", id)
      nil -> map
    end
  end

  defp maybe_put_assignee_actor(map, _), do: map

  defp parse_date(nil), do: nil
  defp parse_date(<<_::binary-10>> = str), do: Date.from_iso8601!(str)
  defp parse_date(_), do: nil
end
