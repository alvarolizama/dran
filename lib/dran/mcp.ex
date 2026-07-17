defmodule Dran.MCP do
  @moduledoc """
  MCP (Model Context Protocol) server for Dran — Streamable HTTP transport.

  Served from Phoenix at `/mcp`. Supports POST, GET, and DELETE per
  MCP spec 2025-03-26 Streamable HTTP transport.

  ## Endpoints
  - `POST /mcp` — send JSON-RPC request → JSON or SSE response
  - `GET /mcp` — open SSE stream for server-initiated messages
  - `DELETE /mcp` — terminate session

  ## Tools (19)
  - `search` — unified full-text, fuzzy, semantic or hybrid search across pages
  - `semantic_search` — deprecated alias for `search` with `strategy=semantic`
  - `create_page` — create a new page (title/slug optional, derived from body)
  - `update_page` — update title, body, tags, or meta; version auto-increments on body change
  - `get_page` — get a page by slug (returns markdown)
  - `delete_page` — delete a page by slug (cascades to relations + versions)
  - `create_todo` — create a todo item
  - `update_todo` — update a todo's kanban status, priority, or due date (merges meta)
  - `create_relation` — create a typed relation between two pages
  - `delete_relation` — delete a relation between two pages (by slug pair + optional type)
  - `get_links` — get inbound + outbound relations for a page
  - `list_pages` — list pages with filters (type, tag, status, owner, created_by, limit)
  - `stats` — aggregate statistics for a context
  - `lint` — run lint report for a context (orphans, stale pages, contested knowledge)
  - `rename_slug` — rename a page's slug and rewrite all `![[old-slug]]` embeds in the same context
  - `reaugment_page` — re-run augmentation (summary/tags/embedding/relations) for a page
  - `ingest_url` — save a URL or download a file as a reference page
  - `start_agent` — start an autonomous agent (`research` or `ingest`)
  - `get_agent_session` — poll an agent session for status and steps

  ## Embeds
  Embeds are auto-resolved into embeds relations on create and update; stale ones
  are removed on body update. Use `![[other-slug]]` in a page body to embed another
  page. `rename_slug` rewrites embed references across the whole context.

  ## Resources
  - `page://{context}/{slug}` — page content as markdown
  - `goal://{context}/{slug}` — goal detail with todos and plans
  - `wiki://{context}/index` — wiki index (all slugs + titles)

  ## Prompts
  - `research_topic` — scaffold a research page
  - `brainstorm` — generate ideas around a topic
  - `goal_review` — review a goal's status
  """

  alias Dran.{Agent, Brain, Repo}
  import Ecto.Query, warn: false

  @protocol_version "2025-03-26"

  @tools [
    %{
      "name" => "search",
      "description" =>
        "Search pages in a context. Returns matching pages with title, slug, type, excerpt, relevance distance, and search source (fts/fuzzy/semantic/hybrid). Use `strategy: \"auto\"` for best results; use `type` to narrow to a page type. Semantic/hybrid strategies require the inference API — they degrade to fts if inference is not configured, which you can detect from the returned `source` field. Example: strategy=hybrid query=\"distributed consensus\" type=note will search note-type pages using keyword+vector matching.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "query" => %{
            "type" => "string",
            "description" =>
              "Natural-language search query. Keywords or a full sentence both work; fuzzy/semantic strategies handle typos and paraphrase."
          },
          "context" => %{
            "type" => "string",
            "description" => "Context slug to search within, e.g. 'personal' or 'work'."
          },
          "type" => %{
            "type" => "string",
            "description" =>
              "Optional filter restricting results to a single page type: note, concept, entity, reference, goal, plan, todo, artifact, comparison, or query.",
            "enum" => [
              "note",
              "concept",
              "entity",
              "reference",
              "goal",
              "plan",
              "todo",
              "artifact",
              "comparison",
              "query"
            ]
          },
          "strategy" => %{
            "type" => "string",
            "enum" => ["auto", "fts", "fuzzy", "semantic", "hybrid"],
            "description" =>
              "Search strategy. 'auto' (default) picks the best available. 'fts' = PostgreSQL full-text (fast, keyword). 'fuzzy' = trigram similarity (typo-tolerant). 'semantic' = vector embedding similarity (requires inference API). 'hybrid' = fts + semantic combined (requires inference API). Semantic/hybrid fall back to fts if inference is unavailable — check the returned `source` to confirm which strategy ran."
          }
        },
        "required" => ["query", "context"]
      }
    },
    %{
      "name" => "semantic_search",
      "description" =>
        "Deprecated alias for `search` with `strategy=semantic`. Kept for backward compatibility — prefer calling `search` with `strategy` explicitly. The `hybrid` boolean here maps to strategy=hybrid when true, otherwise strategy=semantic. Both require the inference API and fall back to fts if it is not configured.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "query" => %{
            "type" => "string",
            "description" => "Natural-language search query."
          },
          "context" => %{
            "type" => "string",
            "description" => "Context slug to search within."
          },
          "type" => %{
            "type" => "string",
            "description" =>
              "Optional filter restricting results to a single page type: note, concept, entity, reference, goal, plan, todo, artifact, comparison, or query.",
            "enum" => [
              "note",
              "concept",
              "entity",
              "reference",
              "goal",
              "plan",
              "todo",
              "artifact",
              "comparison",
              "query"
            ]
          },
          "hybrid" => %{
            "type" => "boolean",
            "description" =>
              "If true, run hybrid (keyword + vector) search; if false (default), run pure semantic (vector) search. Both require the inference API."
          }
        },
        "required" => ["query", "context"]
      }
    },
    %{
      "name" => "create_page",
      "description" => """
      Create a new page in the second brain. Each page has a `page_type` that determines its purpose and what metadata (`meta`) it accepts. If `slug` is omitted it is derived from the title; if `title` is omitted it is derived from the body. **Caveat: creation fails if the slug already exists in the given context** — use `update_page` or `rename_slug` in that case. Use `![[other-slug]]` inside `body` to embed another page; embeds are auto-resolved into `embeds` relations.

      Page types and subtypes (set `meta.kind`):
      - note: thought, journal, idea, meeting, question, quote
      - concept: technique, pattern, discipline, theory
      - entity: person, company, product, tool, place, event
      - reference: article, paper, video, podcast, book
      - artifact: document, code, design, deliverable, file
      - goal: has health (green/yellow/red), target_date
      - plan: has horizon (weekly/monthly/quarterly/yearly), status
      - todo: has kanban_status (backlog/this_week/today/in_progress/done/cancelled), priority (low/medium/high/urgent)
      - comparison: has entities, criteria, verdict
      - query: question+answer; has kind (factual/conceptual/how_to/opinion), difficulty (simple/intermediate/advanced), status (open/answered/verified), answered_by
      """,
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "context" => %{
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
              "URL-friendly kebab-case slug, unique per context. If omitted, derived from the title. Creation fails if this slug already exists in the context — use update_page or rename_slug instead."
          },
          "body" => %{
            "type" => "string",
            "description" =>
              "Page content in Markdown. Use `![[other-slug]]` to embed another page; embeds are auto-resolved into `embeds` relations."
          },
          "page_type" => %{
            "type" => "string",
            "description" =>
              "Page type determining purpose and accepted meta fields. See the description for the meta keys each type expects.",
            "enum" => [
              "note",
              "concept",
              "entity",
              "reference",
              "goal",
              "plan",
              "todo",
              "artifact",
              "comparison",
              "query"
            ]
          },
          "tags" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Tags in kebab-case, e.g. [\"elixir\", \"testing\"]."
          },
          "meta" => %{
            "type" => "object",
            "description" =>
              "Type-specific metadata. Key fields by type: note→{kind, date}, todo→{kanban_status, priority, goal_slug, due_date}, goal→{health, target_date, start_date, team}, plan→{horizon, status}, reference→{source_url, kind}, entity→{kind, aliases, external_url}, concept→{kind, domain, parent_concept}, artifact→{kind, filename, mime_type, storage_path}, comparison→{entities, criteria, verdict}, query→{kind, difficulty, status, answered_by}."
          },
          "summary" => %{
            "type" => "string",
            "description" => "Optional one-line summary shown in listings."
          },
          "owner" => %{
            "type" => "string",
            "description" => "Owner identity for the page (defaults to 'agent')."
          },
          "created_by" => %{
            "type" => "string",
            "description" =>
              "Who created this page, recorded for provenance (defaults to 'agent')."
          }
        },
        "required" => ["context", "page_type"]
      }
    },
    %{
      "name" => "update_page",
      "description" =>
        "Update an existing page by slug. Pass only the fields you want to change (title, body, tags, meta, summary). Changing `body` auto-increments the page version and re-resolves `![[slug]]` embeds into relations. Returns the new title and version number. Returns an error if the page slug is not found in the context.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "context" => %{
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
          "updated_by" => %{
            "type" => "string",
            "description" => "Who is updating the page, for provenance (defaults to 'agent')."
          }
        },
        "required" => ["context", "slug"]
      }
    },
    %{
      "name" => "get_page",
      "description" =>
        "Read a single page by slug. Returns the full Markdown body plus a metadata footer (type, tags, version). Use this to fetch content for reading or analysis; use `list_pages` for lightweight metadata-only listings. Returns an error if the slug is not found in the context.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "context" => %{
            "type" => "string",
            "description" => "Context slug containing the page."
          },
          "slug" => %{
            "type" => "string",
            "description" => "Slug of the page to read."
          }
        },
        "required" => ["context", "slug"]
      }
    },
    %{
      "name" => "create_todo",
      "description" =>
        "Create a todo item (page_type=todo). Todos carry `kanban_status` (backlog → this_week → today → in_progress → done | cancelled) and `priority` (low, medium, high, urgent). Optionally link to a goal via `goal_slug`. Example: kanban_status=\"today\" priority=\"high\" goal_slug=\"ship-v1\". Creation fails if the slug already exists in the context. Returns the created todo's slug and status.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "context" => %{
            "type" => "string",
            "description" => "Context slug where the todo will be created."
          },
          "title" => %{
            "type" => "string",
            "description" => "Todo title (human-readable)."
          },
          "slug" => %{
            "type" => "string",
            "description" =>
              "URL-friendly kebab-case slug, unique per context. Creation fails if it already exists."
          },
          "goal_slug" => %{
            "type" => "string",
            "description" =>
              "Slug of the goal this todo belongs to (optional). Set this to group todos under a goal."
          },
          "body" => %{
            "type" => "string",
            "description" => "Todo description in Markdown (optional)."
          },
          "priority" => %{
            "type" => "string",
            "description" => "Priority level: low, medium, high, or urgent (default: medium).",
            "enum" => ["low", "medium", "high", "urgent"]
          },
          "kanban_status" => %{
            "type" => "string",
            "description" =>
              "Kanban board column: backlog, this_week, today, in_progress, done, or cancelled (default: backlog). Typical progression: backlog → this_week → today → in_progress → done.",
            "enum" => ["backlog", "this_week", "today", "in_progress", "done", "cancelled"]
          },
          "due_date" => %{
            "type" => "string",
            "description" => "Due date in YYYY-MM-DD format (optional)."
          },
          "owner" => %{
            "type" => "string",
            "description" => "Owner identity for the todo (defaults to 'agent')."
          },
          "created_by" => %{
            "type" => "string",
            "description" => "Who created this todo, for provenance (defaults to 'agent')."
          }
        },
        "required" => ["context", "title", "slug"]
      }
    },
    %{
      "name" => "lint",
      "description" =>
        "Run a quality lint report for a context. Returns three categories: orphan pages (no inbound links, likely disconnected), stale pages (not updated in 90+ days, possibly outdated), and contested pages (conflicting knowledge flagged by the system). Use this during maintenance or cleanup to find pages needing attention.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "context" => %{
            "type" => "string",
            "description" => "Context slug to lint."
          }
        },
        "required" => ["context"]
      }
    },
    %{
      "name" => "ingest_url",
      "description" =>
        "Save a URL into the second brain as a reference page. For HTML pages, stores the URL so content can be read later. For files (PDF, documents, images), downloads and stores the file with a download link. **This tool does NOT extract or parse content** — it only bookmarks/stores the source; use `get_page` or the URL directly to read content afterward. Returns the created reference page's slug and type.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "context" => %{
            "type" => "string",
            "description" => "Context slug where the reference page will be created."
          },
          "url" => %{
            "type" => "string",
            "description" =>
              "URL to ingest — an HTML article, web page, or a direct file URL (PDF, image, document)."
          },
          "slug" => %{
            "type" => "string",
            "description" =>
              "Custom slug for the reference page (auto-derived from the page title if omitted)."
          },
          "tags" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Tags to attach to the reference page (optional)."
          }
        },
        "required" => ["context", "url"]
      }
    },
    %{
      "name" => "delete_page",
      "description" =>
        "Delete a page by slug. **This is irreversible** — cascading deletes remove all relations to/from the page and all page version history. Always confirm with the user before calling. Returns a confirmation with the deleted page's title and slug, or an error if not found.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "context" => %{
            "type" => "string",
            "description" => "Context slug containing the page."
          },
          "slug" => %{
            "type" => "string",
            "description" =>
              "Slug of the page to delete. All relations and version history for this page will be removed."
          }
        },
        "required" => ["context", "slug"]
      }
    },
    %{
      "name" => "create_relation",
      "description" =>
        "Create a typed, directed relation from a source page to a target page. Relation types: `related` (generic link), `contradicts` (source disagrees with target), `supersedes` (source replaces/outdates target), `part_of` (source is a component of target), `embeds` (source embeds target — usually auto-created by `![[slug]]`). Returns an error if either slug is not found in the context. Duplicate relations on the same pair/type are idempotent.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "context" => %{
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
        "required" => ["context", "source_slug", "target_slug"]
      }
    },
    %{
      "name" => "get_links",
      "description" =>
        "Get all inbound and outbound relations for a page. Returns two lists: outbound (pages this page links to, with relation type and target title/slug) and inbound (pages linking to this page, with source title/slug and relation type). Use this to understand a page's connections before editing or deleting. Returns an error if the slug is not found.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "context" => %{
            "type" => "string",
            "description" => "Context slug containing the page."
          },
          "slug" => %{
            "type" => "string",
            "description" => "Slug of the page whose relations to retrieve."
          }
        },
        "required" => ["context", "slug"]
      }
    },
    %{
      "name" => "list_pages",
      "description" =>
        "List pages in a context with optional filters. Returns lightweight metadata only (title, slug, type) — no body content. Use `type` to list a specific page type (e.g. all todos or goals), `tag` to filter by tag, and `status` to filter todos by kanban status. Use this for overviews and discovery; use `get_page` to read full content. Results are capped at `limit` (default 50, max 500).",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "context" => %{
            "type" => "string",
            "description" => "Context slug to list pages from."
          },
          "type" => %{
            "type" => "string",
            "description" =>
              "Optional filter by page type: note, concept, entity, reference, goal, plan, todo, artifact, comparison, or query.",
            "enum" => [
              "note",
              "concept",
              "entity",
              "reference",
              "goal",
              "plan",
              "todo",
              "artifact",
              "comparison",
              "query"
            ]
          },
          "tag" => %{
            "type" => "string",
            "description" => "Optional filter: only pages with this tag."
          },
          "status" => %{
            "type" => "string",
            "description" =>
              "Optional filter for todos by kanban_status: backlog, this_week, today, in_progress, done, or cancelled.",
            "enum" => ["backlog", "this_week", "today", "in_progress", "done", "cancelled"]
          },
          "limit" => %{
            "type" => "integer",
            "description" => "Maximum number of results (default 50, hard max 500)."
          },
          "owner" => %{
            "type" => "string",
            "description" => "Optional filter: only pages whose `owner` matches this value."
          },
          "created_by" => %{
            "type" => "string",
            "description" =>
              "Optional filter: only pages whose `created_by` (provenance) matches this value."
          }
        },
        "required" => ["context"]
      }
    },
    %{
      "name" => "update_todo",
      "description" =>
        "Update a todo's kanban status, priority, due date, goal, title, body, or tags. Meta fields are merged — pass only what you want to change; existing meta keys (kanban_status, priority, due_date, goal_slug) are preserved. Note that `tags` replaces the existing tag list entirely. Returns the updated todo's title, slug, and current kanban status.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "context" => %{
            "type" => "string",
            "description" => "Context slug containing the todo."
          },
          "slug" => %{
            "type" => "string",
            "description" => "Slug of the todo page to update."
          },
          "kanban_status" => %{
            "type" => "string",
            "description" =>
              "New kanban status: backlog, this_week, today, in_progress, done, or cancelled (optional). Typical progression: backlog → this_week → today → in_progress → done.",
            "enum" => ["backlog", "this_week", "today", "in_progress", "done", "cancelled"]
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
          "goal_slug" => %{
            "type" => "string",
            "description" =>
              "Slug of a goal to link this todo to (optional). Replaces the existing goal_slug."
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
          }
        },
        "required" => ["context", "slug"]
      }
    },
    %{
      "name" => "delete_relation",
      "description" =>
        "Delete relations between two pages. If `relation_type` is provided, only relations of that type are deleted; if omitted, ALL relations between the two pages (both directions) are deleted. Use `get_links` first to inspect existing relations before deleting. Returns the count of deleted relations.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "context" => %{
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
        "required" => ["context", "source_slug", "target_slug"]
      }
    },
    %{
      "name" => "stats",
      "description" =>
        "Get aggregate statistics for a context. Returns total page count, pages broken down by type, todos broken down by kanban status, orphan count, total relations, and broken-link count. Use this for dashboard overviews, weekly reviews, or to check the overall health of a context.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "context" => %{
            "type" => "string",
            "description" => "Context slug to get statistics for."
          }
        },
        "required" => ["context"]
      }
    },
    %{
      "name" => "rename_slug",
      "description" =>
        "Rename a page's slug. Updates the page's slug in place; version history and relations are preserved. **Fails if `new_slug` already exists** in the context, and returns an error if `old_slug == new_slug`. All `![[old-slug]]` embeds in other pages of the same context are rewritten automatically. Use this to fix a wrongly named page without deleting and recreating it.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "context" => %{
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
        "required" => ["context", "old_slug", "new_slug"]
      }
    },
    %{
      "name" => "reaugment_page",
      "description" =>
        "Re-run the augmentation pipeline for a page: regenerate summary/tags/embedding and refresh semantic relations. Use when inference was unavailable or the page body changed significantly. Clears the stored `embedding_hash` so the pipeline treats the page as stale, then schedules async augmentation.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "context" => %{
            "type" => "string",
            "description" => "Context slug containing the page."
          },
          "slug" => %{
            "type" => "string",
            "description" => "Slug of the page to reaugment."
          }
        },
        "required" => ["context", "slug"]
      }
    },
    %{
      "name" => "start_agent",
      "description" =>
        "Start an autonomous agent session and return immediately. `research` agents explore a topic and create pages; `ingest` agents fetch a URL and save its content. Returns a session_id and track_url — poll `get_agent_session` with that session_id to check progress, steps, and summary. The agent runs asynchronously in the background.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "agent_type" => %{
            "type" => "string",
            "enum" => ["research", "ingest"],
            "description" =>
              "'research' = explore a topic and create pages from findings. 'ingest' = fetch a URL and save its content as a reference page."
          },
          "context" => %{
            "type" => "string",
            "description" => "Context slug where the agent will create pages."
          },
          "input" => %{
            "type" => "string",
            "description" =>
              "For research: a topic or question to explore. For ingest: a URL to fetch and save."
          },
          "opts" => %{
            "type" => "object",
            "description" =>
              "Optional agent configuration options (e.g. max pages, tags). Passed through to the agent."
          }
        },
        "required" => ["agent_type", "context", "input"]
      }
    },
    %{
      "name" => "get_agent_session",
      "description" =>
        "Poll an autonomous agent session for status, summary, and step-by-step progress. Returns the session's type, input, status (pending/running/completed/failed), summary, pages_created count, and an ordered list of steps with tool name and result status. Poll periodically until status is 'completed' or 'failed'. Returns an error if the session_id is invalid or not found.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "session_id" => %{
            "type" => "string",
            "description" => "UUID of the agent session to poll (returned by start_agent)."
          }
        },
        "required" => ["session_id"]
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
         %{"context" => context_slug, "page_type" => page_type} = args
       ) do
    context = Brain.get_context_by_slug(context_slug)

    if context do
      attrs =
        %{
          context_id: context.id,
          title: Map.get(args, "title"),
          slug: Map.get(args, "slug"),
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
      case Dran.Agent.Ingest.Utils.do_ingest(context, url, args) do
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
      opts = if args["owner"], do: Keyword.put(opts, :owner, args["owner"]), else: opts

      opts =
        if args["created_by"],
          do: Keyword.put(opts, :created_by, args["created_by"]),
          else: opts

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
                # Brain.rename_slug updates the page's slug in place and rewrites
                # all ![[old-slug]] embeds in other pages of the same context.
                Brain.rename_slug(page, new_slug)

                "Renamed '#{old_slug}' → '#{new_slug}'. Updated ![[#{old_slug}]] references in this context."

              _existing ->
                "Error: a page with slug '#{new_slug}' already exists"
            end
        end
      end
    else
      "Error: context '#{context_slug}' not found"
    end
  end

  defp execute_tool(
         "start_agent",
         %{"agent_type" => agent_type, "context" => context_slug, "input" => input} = args
       ) do
    context = Brain.get_context_by_slug(context_slug)

    if context do
      opts = Map.get(args, "opts", [])

      case start_agent_by_type(agent_type, input, context.id, opts) do
        {:ok, session} ->
          """
          Started #{agent_type} agent session.

          - session_id: #{session.id}
          - status: #{session.status}
          - track_url: /agents/#{agent_type}/#{session.id}

          Poll `get_agent_session` with session_id for updates.
          """

        {:error, reason} ->
          "Error: failed to start agent: #{inspect(reason)}"
      end
    else
      "Error: context '#{context_slug}' not found"
    end
  end

  defp execute_tool("get_agent_session", %{"session_id" => session_id}) do
    case Ecto.UUID.cast(session_id) do
      {:ok, id} ->
        case Repo.get(Agent.Session, id) do
          nil ->
            "Error: session not found"

          session ->
            steps =
              Repo.all(
                from(s in Agent.Step,
                  where: s.session_id == ^session.id,
                  order_by: [asc: s.step_number]
                )
              )

            render_session(session, steps)
        end

      :error ->
        "Error: invalid session_id"
    end
  end

  defp execute_tool("reaugment_page", %{"context" => context_slug, "slug" => slug}) do
    context = Brain.get_context_by_slug(context_slug)

    if context do
      case Brain.get_page_by_slug(slug, context.id) do
        nil ->
          "Error: page '#{slug}' not found in context '#{context_slug}'"

        page ->
          # Clear embedding_hash so the augmenter treats the page as stale,
          # then schedule async augmentation (summary/tags/embedding/relations).
          Ecto.Changeset.change(page, embedding_hash: nil) |> Repo.update!()
          Brain.PageAugmenter.schedule(page)
          "Reaugmentation scheduled for '#{slug}'"
      end
    else
      "Error: context '#{context_slug}' not found"
    end
  end

  defp execute_tool(tool_name, _args) do
    "Error: unknown tool '#{tool_name}'"
  end

  # ── Agent helpers ─────────────────────────────────────────────────────────

  defp start_agent_by_type("research", input, context_id, opts),
    do: Agent.Research.run(input, context_id, opts)

  defp start_agent_by_type("ingest", input, context_id, opts),
    do: Agent.Ingest.run(input, context_id, opts)

  defp start_agent_by_type(_type, _input, _context_id, _opts),
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
          4. Suggest tags to related topics

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
          Use page_type 'note' with meta.kind 'idea' and interlink them with create_relation where relevant.
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
