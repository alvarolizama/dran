---
name: second-brain
description: "Use when operating Álvaro's personal second brain via the Dran MCP server. 19 tools for capturing, relating, querying and maintaining typed knowledge pages (notes, concepts, entities, references, goals, plans, todos, artifacts, comparisons, queries) as a knowledge graph. Triggers on anything Dran / segundo cerebro / brain: thoughts, notes, research, URLs, goals, todos, comparisons, weekly reviews, or delegating longer tasks to agents."
version: 3.0.0
author: Álvaro Lizama
license: MIT
metadata:
  hermes:
    tags: [dran, second-brain, mcp, knowledge-graph, notes, productivity]
    related_skills: [obsidian, notion, apple-notes]
---

# second-brain — Dran MCP Skill

## 1. Overview

### What is Dran

Dran is a personal second-brain application that stores knowledge as a
**directed graph** inside a context (workspace). It is accessed through a
**Model Context Protocol (MCP)** endpoint — every operation goes through MCP
tools. There is no need to use the REST API or the web UI for agent-driven
workflows.

**Load this skill when:**

- Álvaro mentions Dran, the "segundo cerebro", knowledge graph, notes,
  goals/plans/todos, research, articles/URLs, comparisons, or agents.
- You need to capture, update, relate, or query durable knowledge.

**Do not use for:**

- Ephemeral chat (use the `memory` tool).
- Session-only state.
- Duplicating content that already lives in another canonical system.

### Architecture Summary

Dran stores knowledge as:

- **Pages** — typed knowledge nodes (`note`, `concept`, `entity`, `reference`,
  `goal`, `plan`, `todo`, `artifact`, `comparison`, `query`).
- **Relations** — directed links between pages (`semantic`, `related`, `part_of`,
  `supersedes`, `contradicts`, `embeds`).
- **Embeddings** — every page is embedded as a vector. After `create_page` /
  `update_page`, the `PageAugmenter` asynchronously creates **`semantic`**
  relations to the closest neighbours.

### Tech Stack

- **Language:** Elixir (~> 1.15) on OTP 26+
- **Web framework:** Phoenix 1.8 with LiveView 1.2
- **Database:** PostgreSQL 14+ with `pg_trgm`, `uuid-ossp`, and `pgvector`
- **HTTP server:** Bandit
- **Frontend:** Tailwind CSS v4, TipTap WYSIWYG editor, esbuild
- **Vector storage:** pgvector
- **HTTP client:** Req (not HTTPoison/Tesla/httpc)
- **Markdown:** mdex
- **AI integration:** OpenAI-compatible inference API (embeddings, rerank, chat,
  vision, ASR, MarkItDown)
- **Scheduler:** Quantum (cron-style jobs for curator and weekly review)

---

## 2. Development

### Project Structure

```
lib/
  dran/            — Core domain (brain, embeddings, inference, ingest, agents, relations)
  dran/agent/      — Autonomous agents (research, ingest, ask, curator, link_gardener, weekly_review)
  dran/inference/  — LLM/embedding/rerank/vision/ASR/MarkItDown clients
  dran_web/        — Web layer (controllers, LiveView, components, plugs, router)
config/            — Phoenix config (dev, test, prod, runtime)
test/              — ExUnit tests (mirrors lib/ structure)
priv/repo/         — Migrations and seeds
rel/               — Release overlays (migrate, server scripts)
assets/            — JS/CSS bundles (esbuild + Tailwind)
references/        — Supporting documentation
```

### Coding Conventions

- Use `mix precommit` when done with all changes — it runs
  `compile --warnings-as-errors`, `deps.unlock --unused`, `format`, and `test`.
- Use the built-in `Req` library for HTTP requests — **never** `:httpoison`,
  `:tesla`, or `:httpc`.
- LiveView templates **must** begin with `<Layouts.app flash={@flash} ...>`.
- Use the `<.icon>` component for icons — **never** `Heroicons` modules.
- Use the imported `<.input>` component for form inputs.
- Use Tailwind CSS classes and custom CSS rules (no `@apply` in raw CSS).
- Never nest multiple modules in the same file.
- Elixir lists use `Enum.at` for index access, not `mylist[i]`.
- In `if`/`case`/`cond` blocks, bind the result to a variable outside the block.

### Testing

```bash
mix test              # Create test DB, migrate, run all tests
mix test test/dran/    # Run domain-layer tests only
mix test test/dran_web/  # Run web-layer tests only
```

Tests auto-create and migrate the test database via the `test` alias.

---

## 3. MCP API

### Connection

| Item | Value |
| --- | --- |
| Transport | Streamable HTTP, MCP spec 2025-03-26 |
| POST | `POST http://<dran-host>/api/mcp` |
| Auth | `Authorization: Bearer ***` |
| Default context | **`personal`** — do not ask, do not switch unless Álvaro says otherwise |
| Config | `~/.hermes/config.yaml` → `mcp_servers.dran` |

- Requests need an `id` to get a JSON response. Notifications (`method` with no
  `id`) return `202` with an empty body.
- The server returns an `mcp-session-id` header on `initialize`.
- If the endpoint returns `401`, check the env var before assuming Dran is down.

### Tools

| Tool | Purpose |
| --- | --- |
| `create_page` | Create any page type (except todos — use `create_todo`). |
| `create_todo` | Create a todo with status/priority/goal linkage. |
| `update_page` | Update title/body/tags/meta. **Replaces** `meta` entirely. |
| `update_todo` | Update todo status/priority/date. **Merges** `meta`. |
| `rename_slug` | Rename a page slug. Rewrites `![[old-slug]]` embeds across the context. |
| `delete_page` | Delete a page (irreversible, cascades to relations/versions). |
| `create_relation` | Create an explicit typed relation between pages. |
| `delete_relation` | Delete relations between two pages (optionally by type). |
| `search` | Unified search: auto picks FTS, fuzzy, semantic or hybrid. Use `type` filter when you can. |
| `semantic_search` | Deprecated alias for `search` with `strategy=semantic`. Prefer `search`. |
| `get_page` | Full markdown body of one page. Use this to actually read. |
| `list_pages` | Filtered lightweight list (type, tag, status, limit). |
| `get_links` | Inbound + outbound relations for a page. |
| `ingest_url` | Save a URL as a `reference` page, or download a file. With inference enabled, extracts content (MarkItDown/Vision/ASR). |
| `stats` | Dashboard: totals, pages by type, todos by status, orphans, relations. |
| `lint` | Orphans, stale pages (>90d), contested knowledge. |
| `reaugment_page` | Re-run the augmentation pipeline (summary/tags/embedding/relations) for a page. |
| `start_agent` | Launch an autonomous agent (see Agents section below). |
| `get_agent_session` | Poll an autonomous agent's progress and results. |

### Resources (read-only)

Prefer these over looping `list_pages` when you need an overview:

| URI | Returns |
| --- | --- |
| `page://{context}/{slug}` | Full page markdown |
| `goal://{context}/{slug}` | Goal + linked todos/plans as JSON |
| `wiki://{context}/index` | Full index of the context (slug + title + type) |

### Prompts

| Prompt | Use |
| --- | --- |
| `research_topic` | Scaffold a research page (outline, sources, questions). |
| `brainstorm` | Generate 5-10 interlinked idea pages. |
| `goal_review` | Review a goal, its todos and plans, suggest next actions. |

### Autonomous Agents

For multi-step research, ingest, Q&A, or maintenance tasks, delegate with
`start_agent` and poll with `get_agent_session`:

| Agent | Purpose | Key limits |
| --- | --- | --- |
| `research` | Searches/scrapes the web and creates `note`/`reference` pages. | max_sources=10, max_pages=10 (configurable via Settings); max 10 search queries. |
| `ingest` | Validates, inspects, downloads a URL and creates a `reference` page. | File download limit 100 MiB. |
| `ask` | Answers a question using **only** knowledge already in the brain; persists the answer as a `query` page. | max 5 search queries; one query page per session. |
| `curator` | Reviews pairs of pages with very similar embeddings, flags duplicates/contested content, writes a report note. | max 20 flags per session; duplicate threshold 0.05. |
| `link_gardener` | Reads orphaned/under-linked pages, proposes typed relations with justifications. | max 10 proposals per session; `semantic` type forbidden. |
| `weekly_review` | Gathers brain stats and writes a weekly review journal page (in Spanish). | Window: pages created in last 7 days. |

```json
{
  "agent_type": "research",
  "context": "personal",
  "input": "Yeshe Walmo"
}
```

**Session lifecycle:** agents run asynchronously. Poll `get_agent_session` with
the `session_id` returned by `start_agent` until `status` is `done` or `failed`.
Failed sessions (crashes, timeouts, max consecutive errors) are marked
`failed` with a summary explaining the cause. Each session tracks
`meta.tokens_used` (accumulated LLM token usage) and `meta.model` for
cost/usage tracking.

> **Note:** the `start_agent` tool's `agent_type` enum in the MCP schema
> advertises `["research", "ingest"]`, but the server dispatches all six types
> above. Pass the `agent_type` string directly; it will be routed correctly.

There is no dedicated search agent; for search-only tasks use `search` directly.

---

## 4. Configuration

### Environment Variables

Copy `.env.example` to `.env` and fill in values. Key variables:

| Variable | Purpose | Default |
| --- | --- | --- |
| `PORT` | Phoenix runtime port | `4000` |
| `PHX_HOST` | Public host for URL generation | `localhost` |
| `SECRET_KEY_BASE` | Cookie/session signing key | Generate with `mix phx.gen.secret` |
| `DATABASE_URL` | Ecto connection URL | `ecto://postgres:postgres@localhost/dran_dev` |
| `POOL_SIZE` | DB connection pool size | `10` |
| `DRAN_USERNAME` | Admin username (seeded on first run) | `admin` |
| `DRAN_PASSWORD` | Admin password | `dran` |
| `DRAN_API_TOKEN` | API token for HTTP API / MCP auth | `dran-token` |
| `DRAN_CONTEXT_SLUG` | Default context slug | `personal` |
| `DRAN_CONTEXT_NAME` | Default context name | `Personal` |
| `UPLOADS_DIR` | File upload storage path | `priv/static/uploads` |
| `UPLOADS_MAX_SIZE` | Max upload size in bytes | `104857600` (100 MiB) |
| `DRAN_INFERENCE_API_URL` | OpenAI-compatible inference endpoint | — |
| `DRAN_INFERENCE_API_KEY` | Inference API key | — |
| `FIRECRAWL_API_KEY` | Firecrawl API key for web search/scrape | — |
| `DNS_CLUSTER_QUERY` | Optional libcluster query for distributed Erlang | unset |

Optional inference model overrides: `DRAN_INFERENCE_CHAT_MODEL`,
`DRAN_INFERENCE_EMBEDDING_MODEL`, `DRAN_INFERENCE_RERANK_MODEL`,
`DRAN_INFERENCE_MARKITDOWN_MODEL`, `DRAN_INFERENCE_ASR_MODEL`,
`DRAN_INFERENCE_VISION_MODEL`.

Optional agent tuning: `AGENT_MAX_STEPS` (default 150),
`AGENT_PER_STEP_TIMEOUT` (default 120000 ms).

### Settings (runtime, DB-backed)

Beyond env vars, Dran stores tunable parameters in the `settings` table via
`Dran.Settings`. These are editable at **`/settings`** (Brain tuning section)
without a redeploy:

| Key | Purpose | Default |
| --- | --- | --- |
| `semantic_threshold_short` | Embedding distance threshold for short pages | `0.15` |
| `semantic_threshold_mid` | Threshold for mid-length pages | `0.22` |
| `semantic_threshold_long` | Threshold for long pages | `0.28` |
| `agent_max_pages` | Max pages a research agent may create per session | `10` |
| `agent_max_sources` | Max sources a research agent may scrape per session | `10` |
| `research_lang` | Language for research agent output (es/en) | `es` |
| `daily_note_enabled` | Whether daily note auto-creation is enabled | `true` |

Changes take effect immediately for new agent sessions and augmenter runs.

### Database Setup

PostgreSQL 14+ with extensions `pg_trgm`, `uuid-ossp`, and `pgvector`. The
migration system handles extension creation automatically.

### First-Time Setup

```bash
cp .env.example .env   # Copy and edit env values
mix setup              # deps + DB + migrations + assets + seed
```

`mix setup` runs: `deps.get` → `ecto.create` → `ecto.migrate` →
`assets.setup` → `assets.build` → `seed`.

Useful aliases:

- `mix ecto.reset` — drop, create, migrate, seed (full DB reset).
- `mix assets.deploy` — minify and digest assets for production.
- `mix precommit` — compile with warnings-as-errors, unlock unused deps,
  format, and test.

---

## 5. User Guide

### Working Rules

1. **Search before create.** Run 2-3 related `search` queries before every
   `create_page`. If a relevant page exists, update it.
2. **Read before answer.** When Álvaro asks "what do I know about X?",
   `search`, then `get_page` the top 2-3 results. Do not answer from excerpts.
3. **Infer when obvious, ask when risky.** Infer page type, slug and tags from
   context. Ask before deleting, renaming, or touching identity/finances.
4. **Edit > duplicate.** Updating an existing page is almost always better than
   creating a new one.

### Page Types

| Type | Use it for | Subtypes (`meta.kind`) | Key `meta` fields |
| --- | --- | --- | --- |
| `note` | Thoughts, journal, ideas, meetings, questions, quotes | thought, journal, idea, meeting, question, quote | kind, date, author, attendees, resolved, source_ref |
| `concept` | Techniques, patterns, disciplines, theories | technique, pattern, discipline, theory | kind, domain, parent_concept |
| `entity` | People, companies, products, tools, places, events | person, company, product, tool, place, event | kind, aliases, external_url, location |
| `reference` | External sources | article, paper, video, podcast, book | kind, source_url, published_at |
| `artifact` | Files, code snippets, designs, deliverables | document, code, design, deliverable, file | kind, filename, mime_type, storage_path, sha256 |
| `goal` | Objectives with target date | — | health (green/yellow/red), start_date, target_date, team |
| `plan` | Time-horizoned plans | — | horizon, status, period, goal_slug |
| `todo` | Actionable items | — | kanban_status, priority, due_date, goal_slug, assignee |
| `comparison` | Side-by-side analyses | — | entities, criteria, verdict |
| `query` | Questions with answers | factual, conceptual, how_to, opinion | kind, difficulty, answer_status, answered_by |

Default to `note` when unsure. Promote later with `update_page`.

### Meta Validation Reference

| `page_type` | Field | Valid values |
| --- | --- | --- |
| `note` | `kind` | thought, journal, idea, meeting, question, quote |
| `concept` | `kind` | technique, pattern, discipline, theory |
| `entity` | `kind` | person, company, product, tool, place, event |
| `reference` | `kind` | article, paper, video, podcast, book |
| `artifact` | `kind` | document, code, design, deliverable, file |
| `todo` | `kanban_status` | backlog, this_week, today, in_progress, done, cancelled |
| `todo` | `priority` | low, medium, high, urgent |
| `goal` | `health` | green, yellow, red |
| `plan` | `horizon` | weekly, monthly, quarterly, yearly |
| `plan` | `status` | draft, active, on_hold, completed, archived |
| `query` | `kind` | factual, conceptual, how_to, opinion |
| `query` | `difficulty` | simple, intermediate, advanced |
| `query` | `answer_status` | open, answered, verified |

### Creating Pages

Use `create_page` for everything except todos. `title` and `slug` are optional:
if omitted, Dran derives them from the first non-empty line of `body`.

```json
{
  "context": "personal",
  "page_type": "note",
  "body": "Today I learned that Elixir's `=` is actually a match operator, not an assignment.",
  "meta": { "kind": "journal", "date": "2026-06-27" },
  "tags": ["elixir", "programming"]
}
```

For todos, always use **`create_todo`** (not `create_page` with `page_type=todo`):

```json
{
  "context": "personal",
  "title": "Refactor MCP controller",
  "slug": "refactor-mcp-controller",
  "goal_slug": "dran-mvp",
  "priority": "high",
  "kanban_status": "this_week",
  "due_date": "2026-06-28"
}
```

After `create_page` / `update_page`, Dran automatically:

1. Extracts/refines `title`, `summary`, `tags` and inline links via inference.
2. Generates and stores an embedding.
3. Creates **`semantic`** relations to similar pages.
4. Resolves `![[slug]]` embeds into `embeds` relations (and cleans stale ones
   on update).

Plain `[[slug]]` wikilinks are **not supported**. Use `![[slug]]` only to embed
artifacts (it auto-creates an `embeds` relation), and `create_relation` for
explicit typed relationships.

### Editing, Renaming & Deleting

| Action | Tool | Notes |
| --- | --- | --- |
| Change title/body/tags/meta | `update_page` | **Replaces** `meta` entirely. Body change bumps `version`. |
| Change todo status/priority/date | `update_todo` | **Merges** `meta`. This is the only way to change todo status safely. |
| Change slug | `rename_slug` | Existing `![[old-slug]]` embeds in other pages are rewritten automatically. |
| Re-run augmentation | `reaugment_page` | Clears `embedding_hash` and schedules a fresh augmenter pass (summary/tags/embedding/relations). |
| Delete | `delete_page` | **Irreversible**, cascades to relations and versions. Always confirm with Álvaro. |

Example `update_todo`:

```json
{
  "context": "personal",
  "slug": "refactor-mcp-controller",
  "kanban_status": "done"
}
```

### Relations & The Graph

**Automatic:**

- **`semantic`** relations are created by `PageAugmenter` based on embeddings.
  Never create them manually.
- **`embeds`** relations are created automatically when a page body contains
  `![[artifact-slug]]`.

**Manual** — use `create_relation` for explicit, directed links:

| Type | Meaning | Example |
| --- | --- | --- |
| `related` | Generic manual link | `learning-elixir` → `elixir` |
| `part_of` | A is part of B | `tummo` → `six-yogas-of-naropa` |
| `supersedes` | A replaces B | `phoenix-1.8` → `phoenix-1.7` |
| `contradicts` | A conflicts with B | `new-study` → `old-study` |
| `embeds` | A embeds B (auto from `![[slug]]`) | — |

Inspect relations with `get_links`. Remove relations with `delete_relation`.

### Searching

| Tool | Purpose |
| --- | --- |
| `search` | Unified search: auto picks FTS, fuzzy, semantic or hybrid. Use `type` filter when you can. |
| `semantic_search` | Deprecated alias for `search` with `strategy=semantic`. Prefer `search`. |
| `get_page` | Full markdown body of one page. Use this to actually read. |
| `list_pages` | Filtered lightweight list (type, tag, status, limit). |
| `get_links` | Inbound + outbound relations for a page. |
| `stats` | Dashboard: totals, pages by type, todos by status, orphans, relations. |
| `lint` | Orphans, stale pages (>90d), contested knowledge. |

### Ingesting URLs & Files

`ingest_url` saves a URL as a `reference` page, or downloads a file and stores it.

```json
{
  "context": "personal",
  "url": "https://example.com/article.html",
  "slug": "example-article",
  "tags": ["research"]
}
```

- SSRF protection blocks `localhost`, private IPs and CGNAT ranges. Do not pass
  local URLs.
- For local files, upload them to a temporary host first, or paste the text into
  an `artifact`/`note` page directly.

#### Ingest with extraction

When the inference API is configured, `ingest_url` (and the `ingest` agent)
automatically extract content from downloaded files before creating the page.
The extraction strategy is chosen by content type:

| Content type | Strategy | What it does |
| --- | --- | --- |
| PDF, DOCX, PPTX, PPT, DOC, TXT | **MarkItDown** | Converts the file to Markdown via the MarkItDown model. |
| Images (`image/*`) | **Vision** | Generates a detailed description (in Spanish) of the image. |
| Audio (`audio/*`) | **ASR** | Transcribes the audio to text. |

If inference is disabled or extraction fails, the page falls back to a plain
download link — preserving the original behaviour. The page body always includes
the source URL; extracted content (markdown / description / transcript) is
appended below it.

### Scheduled Agents

Two agents run on a schedule via the Quantum cron scheduler
(see `config/config.exs`). Both operate on the default context
(`DRAN_CONTEXT_SLUG`):

| Job | Schedule | Agent | What it does |
| --- | --- | --- | --- |
| `curator_daily` | `0 6 * * *` (daily, 06:00) | `curator` | Finds duplicate/contested page pairs and writes a curator report note. |
| `weekly_review` | `0 8 * * 0` (Sundays, 08:00) | `weekly_review` | Gathers brain stats and writes a weekly review journal page. |

Scheduled jobs are disabled in the `test` environment (`config/test.exs` sets
`jobs: []`).

### Recipes

#### Capture a thought

```
1. search(body keywords, "personal")
2. create_page({ context: "personal", page_type: "note", body: "...", meta: { kind: "thought" } })
```

#### Capture meeting notes

```json
{
  "context": "personal",
  "page_type": "note",
  "body": "... notes ...",
  "meta": { "kind": "meeting", "date": "2026-06-27", "attendees": ["Álvaro", "Paty"] }
}
```

#### Process a research article

```
1. ingest_url({ url, context: "personal", tags: ["research"] })
2. Read the content with web_extract(url).
3. If valuable, create_page({ page_type: "note", body: "Summary..." })
4. create_relation({ source_slug: "<note>", target_slug: "<reference>", relation_type: "part_of" })
```

#### Add a todo to a goal

```
1. search("<goal name>", "personal", type: "goal")
2. create_todo({ title, slug, goal_slug: "<goal>", kanban_status: "this_week", priority: "high" })
```

#### Mark a todo done

```json
{
  "context": "personal",
  "slug": "<todo-slug>",
  "kanban_status": "done"
}
```

Use `update_todo`, not `update_page`.

#### Weekly review

```
1. stats({ context: "personal" })
2. list_pages({ context: "personal", type: "goal" })
3. goal://personal/<goal-slug> for active goals
4. list_pages({ context: "personal", type: "todo", status: "in_progress" })
5. lint({ context: "personal" })
```

#### Create a comparison

```json
{
  "context": "personal",
  "page_type": "comparison",
  "title": "Phoenix vs Rails",
  "body": "...",
  "meta": { "entities": ["phoenix", "rails"], "criteria": ["performance", "concurrency", "ecosystem"], "verdict": "Phoenix for real-time; Rails for CRUD speed." }
}
```

### Common Mistakes

- **Creating without searching.** Always search first.
- **Using `create_page` for todos.** Use `create_todo`.
- **Using `update_page` to change todo status.** Use `update_todo` so meta merges.
- **Creating `semantic` relations manually.** They are automatic.
- **Using `[[slug]]` wikilinks.** Not supported. Use embeddings + relations.
- **Treating `ingest_url` as extraction-only.** It stores and (with inference) extracts.
- **Passing `status` for `query` pages.** Correct field is `answer_status`.
- **Deleting without confirmation.** Always ask Álvaro.
- **Answering from search excerpts.** Read the page with `get_page`.

### Quick Checklist

Before `create_page`:
- [ ] Searched 2-3 variants.
- [ ] Right `page_type` and `meta.kind`/enums.
- [ ] Slug is kebab-case and unique.
- [ ] Tags are kebab-case, 2-5 items.

After changes:
- [ ] Confirm tool response.
- [ ] `lint` after batches; surface orphans/stale pages to Álvaro, do not auto-fix.
- [ ] `stats` for dashboards/weekly reviews.
