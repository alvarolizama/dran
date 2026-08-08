<img src="docs/header.png" alt="Dran — personal second brain" width="100%">

# Dran

A personal second-brain application built with **Phoenix 1.8 + LiveView**. It stores your knowledge as **typed pages** connected by **relations**, forming a queryable knowledge graph.

Includes a TipTap markdown editor, three autonomous agents (curator, link_gardener, graph_rag), an MCP endpoint for AI agent integration, and a REST API.

> **[SKILL.md](skills/dran/SKILL.md)** — Agent operating manual: tools, page types, meta props, recipes, and pitfalls. If you're building an AI agent that connects to Dran via MCP, start there.

## Key features

- **10 page types** — note, concept, entity, reference, project, goal, plan, todo, query, plus `report` (system-created run logs; second-citizen: no graph/journey/embeddings) — each with type-specific metadata and subtypes (`meta.kind`)
- **Markdown editor** — TipTap WYSIWYG with tables, code blocks, mermaid diagrams, and file embeds `![[slug]]`
- **Read-only + edit modes** — pages show rendered markdown + mermaid by default; click *Edit* to switch to the editor
- **Knowledge graph** — 3D graph at `/graph`, hover a node to highlight it and its neighbors, click to navigate; per-page subgraphs at `/graph/:slug`
- **Real-time updates** — page detail views sync live via PubSub when the page changes elsewhere
- **ETS cache** — global graph, per-page subgraphs, and page-by-slug lookups cached in ETS with read concurrency; invalidated on page changes
- **Autonomous agents** — curator (daily cron), link_gardener (weekly cron + manual), graph_rag (manual, GraphRAG search)
- **Scheduled jobs control** — the 5 Quantum crons route through `Dran.Jobs`: runtime toggles, manual "run now", and a `report` page per run, all from Settings → Brain
- **Per-context page type disabling** — restrict which page types appear in a context; enforced via on_mount hooks, sidebar, dashboard, and command palette
- **Custom props** — `meta.props` key-value bag auto-materializes into typed graph relations (role→works_in, tier→has_tier, location→based_in, language→written_in, framework→built_with). See [SKILL.md](skills/dran/SKILL.md) for the full table.
- **Multi-user auth** — Google OAuth + per-user API tokens with context scoping
- **Hybrid search** — full-text, fuzzy, semantic, or hybrid with RRF fusion + PageRank authority boost
- **Version history** with diff, activity feed, runtime settings, and full context export

## Quick start

```bash
git clone git@github.com:alvarolizama/dran.git && cd dran
cp .env.example .env && $EDITOR .env
mix setup    # deps → DB → migrations → assets → seed
mix phx.server
```

Visit [localhost:4000](http://localhost:4000). First run redirects to `/setup` to create the admin account.

## Authentication

- **First run:** `/setup` creates the initial admin. No env-var web credentials.
- **Google OAuth:** appears when `GOOGLE_OAUTH_CLIENT_ID` + `GOOGLE_OAUTH_CLIENT_SECRET` are set. Auto-registers users from allowed domains only.
- **API tokens:** each user gets one `api_token` (Settings → Users). The legacy `DRAN_API_TOKEN` acts as admin. MCP/REST return `401` for invalid tokens, `403` for unassigned contexts.

## Environment variables

See [`.env.example`](.env.example) for the full annotated list. Key ones: `SECRET_KEY_BASE`, `DATABASE_URL`, `PHX_HOST`, `DRAN_API_TOKEN`, `GOOGLE_OAUTH_CLIENT_ID`, `DRAN_INFERENCE_API_URL`.

## Settings

Admin-only at `/settings/:tab`. Tabs: `users` (accounts, tokens, context membership), `contexts` (CRUD + page type toggles), `brain` (semantic thresholds, agent limits, scheduled jobs), `models` (inference config), `system` (read-only), `danger` (reset).

## Page types

| Type | Purpose |
| --- | --- |
| `note` | Thoughts, journal, ideas, meetings |
| `concept` | Techniques, patterns, theories |
| `entity` | People, companies, tools, places |
| `reference` | External sources (articles, papers, videos) |
| `project` | Initiatives grouping goals/plans/todos |
| `goal` | Objectives with measurable targets |
| `plan` | Time-horizoned plans (weekly/quarterly/yearly) |
| `todo` | Actionable items with kanban status |
| `query` | Questions with answers |
| `report` | System-created run logs (`meta.kind: "log"`) — detail view at `/reports/:slug`; excluded from graph, journey, embeddings, and MCP-create |

Pages link via independent `meta.project_slug`, `meta.goal_slug`, `meta.plan_slug` — each materializes a `part_of` relation. No rigid hierarchy; orphans are legitimate.

### Custom props (`meta.props`)

Every page may carry `meta.props`: a free-form key-value bag. Five keys auto-create typed graph relations during augmentation:

| Prop key | Relation | Target |
| --- | --- | --- |
| `role` | `works_in` | entity |
| `tier` | `has_tier` | concept |
| `location` | `based_in` | entity |
| `language` | `written_in` | entity |
| `framework` | `built_with` | entity |

Other keys are stored but generate no edge. Props are GIN-indexed and backfillable via Settings → Brain → "Run backfill".

### Relations

Directed, typed: `related`, `part_of`, `supersedes`, `contradicts`, `embeds` (auto from `![[slug]]`), `semantic` (auto from PageAugmenter). Create explicit ones via `dran_create_relation` or POST /api/relations.

## Autonomous agents

| Agent | Trigger | What it does |
| --- | --- | --- |
| `curator` | Cron daily 06:00 + manual | Finds duplicates and contested knowledge; writes a cleanup report |
| `link_gardener` | Cron weekly (Sun 07:00) + manual (`dran_start_agent`) | Proposes relations for orphaned pages, including transitive `part_of` |
| `graph_rag` | Manual (`dran_start_agent`) | GraphRAG: local/global/drift search, creates query pages with citations |

Quantum crons: `curator_daily` (06:00), `pagerank_nightly` (03:00), `community_summaries_nightly` (03:30), `graph_maintenance_nightly` (03:45), `link_gardener_weekly` (Sun 07:00).

All five route through `Dran.Jobs.run_scheduled/1` and are controlled from **Settings → Brain → "Jobs programados"**: per-job toggle (scheduled runs only), "Correr ahora" (always runs), and last-run status. Each run writes a `report` page (`/reports/:slug`) with status, trigger and duration; the newest 20 per job are kept, older ones archived.

## MCP server

`POST /api/mcp` — Streamable HTTP, MCP spec 2025-03-26. Auth: `Authorization: Bearer <token>`.

**18 tools, 3 agents, 5 resources, 2 prompts** — see [**SKILL.md**](skills/dran/SKILL.md) for the complete operational guide.

```json
{ "mcpServers": { "dran": { "url": "http://localhost:4000/api/mcp", "headers": { "Authorization": "Bearer <token>" } } } }
```

## REST API

Bearer token required, scoped to user's contexts (`?context=<slug>`). Key routes:

| Method | Path | Description |
| --- | --- | --- |
| CRUD | `/api/pages` | Page CRUD |
| GET | `/api/pages/:slug/links` | Page relations |
| GET | `/api/pages/:slug/graph` | Page subgraph |
| GET | `/api/search?q=` | Unified search |
| GET | `/api/graph` | Full knowledge graph |
| CRUD | `/api/contexts` | Context management |
| POST | `/api/mcp` | MCP JSON-RPC |

## Production

```bash
MIX_ENV=prod mix deps.get --only prod
MIX_ENV=prod mix compile
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release
```

Ships with a Dockerfile. Start command: `bin/server`. Runtime env vars only — never bake secrets. See `.env.example` for SSL/VPN dual-access config.

## Tech stack

- Phoenix 1.8 + LiveView
- TipTap v3 editor with `@tiptap/markdown`
- MDEx (comrak) server-side markdown rendering
- Tailwind CSS v4 + daisyUI + `@tailwindcss/typography`
- MCP (Model Context Protocol) for AI agent integration
- Quantum cron scheduler
- ETS cache (GraphCache) with read concurrency
- PostgreSQL with pgvector, FTS, trigram, GIN indexes

## Pre-commit

```bash
mix precommit   # compile --warnings-as-errors → deps.unlock --unused → format → deps.audit → sobelow --exit medium → test
```

## License

MIT