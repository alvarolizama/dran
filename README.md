<img src="docs/header.png" alt="Dran — personal second brain" width="100%">

# Dran

A personal second-brain app built with **Phoenix 1.8 + LiveView**. Your knowledge lives as **typed pages** connected by **typed relations**, forming a queryable knowledge graph — editable in the browser and fully operable by AI agents through **MCP** and a **REST API**.

## Features

### Knowledge
- **10 page types** — `note`, `concept`, `entity`, `reference`, `project`, `goal`, `plan`, `todo`, `query`, plus `report` (system run logs) — each with its own list/new/detail UI (`/notes`, `/concepts`, …)
- **TipTap markdown editor** — WYSIWYG with tables, code blocks, mermaid diagrams, and `![[slug]]` page embeds; pages render read-only by default, *Edit* opens the editor
- **Relations** — directed and typed (`related`, `part_of`, `supersedes`, `contradicts`, `embeds`, `semantic`, `mentions`); link pages freely — no rigid hierarchy, orphans are fine
- **Custom props** — `meta.props` key-value bag; five keys (`role`, `tier`, `location`, `language`, `framework`) auto-materialize into graph edges
- **Version history** — every edit is versioned with diff view on the page detail

### Views
- **Dashboard** (`/`) — context overview
- **Kanban board** (`/kanban`) — all todos, columns `backlog → this_week → today → in_progress → done → cancelled`, drag-drop between columns, combinable filters (project / goal / plan)
- **3D knowledge graph** (`/graph`, `/graph/:slug`) — force-directed 3D; hover highlights a node and its neighbors, click navigates
- **Hybrid search** (`/search`) — full-text, fuzzy, semantic, or hybrid fusion
- **Smart Collections** (`/collections`) — saved live queries rendered as pages
- **Activity feed** (`/activity`), **Journey** (`/journey`), **Tags** (`/tags/:tag`), **Docs** (`/docs`)
- **Multi-context** — switch brains from the sidebar; per-context page-type toggles (Settings → Contexts)

### Automation
- **3 autonomous agents** — `curator` (duplicates/contested cleanup, daily cron), `link_gardener` (proposes relations for orphans, weekly cron + manual), `graph_rag` (GraphRAG search with citations, manual)
- **Scheduled jobs control** — 5 Quantum crons route through `Dran.Jobs`: per-job toggles, "run now" buttons, and a `report` page per run — all from **Settings → Brain**
- **Entity linker** — auto-creates entity pages from real-world names detected in bodies (people, companies, tools); noise-filtered (no file paths, modules, or generic terms) and toggleable from Settings → Brain

### Integration & admin
- **MCP server** — `POST /api/mcp`, Streamable HTTP (MCP spec 2025-03-26), 18 tools + 3 agents + 3 resources + 2 prompts
- **REST API** — token-protected CRUD for pages, relations, contexts, search, export (`/api/*`)
- **Multi-user auth** — first-run `/setup` admin, Google OAuth (invite/domain-restricted), per-user API tokens (Settings → Users)
- **Settings panel** (admin) — users, contexts, API keys, brain tuning, models, system, danger zone (`/settings/:tab`)

## Installation

**Requirements:** Elixir ~> 1.15, Erlang/OTP 26+, PostgreSQL 14+ with the **pgvector** extension, Node (only for asset tooling, handled by `esbuild`/`tailwind` installers).

```bash
git clone git@github.com:alvarolizama/dran.git && cd dran
cp .env.example .env && $EDITOR .env   # fill in the values below
mix setup        # deps → DB create → migrations → assets → seed
mix phx.server
```

Open [localhost:4000](http://localhost:4000) — first run redirects to `/setup` to create the admin account.

## Configuration

All configuration is via environment variables — see [`.env.example`](.env.example) for the full annotated list. The essentials:

| Variable | Purpose |
| --- | --- |
| `SECRET_KEY_BASE` | Session signing — generate with `mix phx.gen.secret` |
| `DATABASE_URL` | Ecto URL, e.g. `ecto://postgres:postgres@localhost/dran_dev` |
| `PHX_HOST` / `PHX_PORT` / `PHX_SCHEME` | Public host/port/scheme for URL generation |
| `DRAN_API_TOKEN` | Legacy admin bearer token for REST/MCP |
| `DRAN_CONTEXT_SLUG` / `DRAN_CONTEXT_NAME` | Default context created on seed |
| `GOOGLE_OAUTH_CLIENT_ID` / `GOOGLE_OAUTH_CLIENT_SECRET` | Optional — enables "Sign in with Google" |
| `GOOGLE_OAUTH_ALLOWED_DOMAINS` | Domains allowed to auto-register via Google |
| `DRAN_INFERENCE_API_URL` / `DRAN_INFERENCE_API_KEY` | OpenAI-compatible inference endpoint (`/v1/embeddings`, `/v1/rerank`, `/v1/chat/completions`) — powers embeddings, summaries, agents, semantic search |
| `DRAN_INFERENCE_CHAT_MODEL` / `DRAN_INFERENCE_EMBEDDING_MODEL` / `DRAN_INFERENCE_RERANK_MODEL` | Optional model overrides per capability |
| `SESSION_SIGNING_SALT` / `SESSION_ENCRYPTION_SALT` | Required in production (`mix phx.gen.secret 32`) |
| `UPLOADS_DIR` | File upload storage path |
| `DISABLE_FORCE_SSL` | Set to `1` **at build time** when serving over plain HTTP (VPN tunnels) |

Inference is optional: without it, Dran still works — you lose embeddings, semantic search, auto-summaries, and agents.

## Using the skills

The [`skills/`](skills/) directory ships **agent operating manuals** — install them into your AI agent (Hermes, Claude Code, or any MCP-capable agent) so it knows how to operate Dran correctly instead of guessing.

| Skill | Use it for |
| --- | --- |
| [`dran`](skills/dran/SKILL.md) | **Start here** — MCP tools reference, page types, props, relations, common recipes and pitfalls |
| [`note-taking-flow`](skills/note-taking-flow/SKILL.md) | Capturing notes, concepts, entities, references |
| [`research-flow`](skills/research-flow/SKILL.md) | Online research stored into the brain |
| [`project-flow`](skills/project-flow/SKILL.md) | Creating/managing projects (strategy layer) |
| [`goal-flow`](skills/goal-flow/SKILL.md) | Measurable objectives under projects |
| [`planning-flow`](skills/planning-flow/SKILL.md) | Tactical plans with roadmaps and todos |
| [`todo-flow`](skills/todo-flow/SKILL.md) | Creating todos (dev or general) with execution steps |
| [`coder-flow`](skills/coder-flow/SKILL.md) | Executing dev todos — phases, gates, evidence |
| [`relations-flow`](skills/relations-flow/SKILL.md) | Connecting pages with typed relations |
| [`maintenance-flow`](skills/maintenance-flow/SKILL.md) | Brain hygiene — orphans, duplicates, stale pages |

**Install (Hermes):** copy the skill folders into `~/.hermes/skills/` (or symlink them) and restart the agent. Each `SKILL.md` has portable frontmatter — other agents can load them the same way.

**Connect the agent to Dran via MCP:**

```json
{
  "mcpServers": {
    "dran": {
      "url": "http://localhost:4000/api/mcp",
      "headers": { "Authorization": "Bearer <your-api-token>" }
    }
  }
}
```

Get your token from **Settings → Users** (per-user token, scoped to your contexts) or use `DRAN_API_TOKEN` for admin access. MCP returns `401` for invalid tokens, `403` for contexts the user can't access.

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
| `report` | System-created agent run logs (detail view only, `/reports/:slug`) |

## Production

```bash
MIX_ENV=prod mix deps.get --only prod
MIX_ENV=prod mix compile
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release   # start with bin/server
```

A `Dockerfile` ships with the repo (Coolify-ready; `/app/bin/migrate` runs migrations as a pre-deploy step). Runtime env vars only — never bake secrets into the image.

## Tech stack

Phoenix 1.8 + LiveView · PostgreSQL + pgvector · TipTap v3 · MDEx (comrak) · Tailwind v4 + daisyUI · Bandit · Quantum (cron) · Req · MCP 2025-03-26

## Pre-commit

```bash
mix precommit   # compile --warnings-as-errors → format → deps audit → sobelow → test
```

## License

MIT
