<div align="center">

<img src="priv/static/favicon.svg" width="96" height="96" alt="Dran" />

# Dran

### Shared memory & knowledge base for AI agent swarms

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Elixir](https://img.shields.io/badge/Elixir-1.15+-4B275F?logo=elixir&logoColor=white)](https://elixir-lang.org)
[![Phoenix](https://img.shields.io/badge/Phoenix-1.8-LiveView-FD4F00?logo=phoenixframework&logoColor=white)](https://www.phoenixframework.org)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-pgvector-336791?logo=postgresql&logoColor=white)](https://www.postgresql.org)
[![MCP](https://img.shields.io/badge/MCP-Server-5B8DEF?logo=modelcontextprotocol&logoColor=white)](https://modelcontextprotocol.io)

</div>

## What is Dran

Dran is the **shared brain an agent swarm reads and writes** — one instance, one graph,
one memory store, shared by every agent and by you.

Two pillars:

- **Knowledge** — a typed, queryable **knowledge graph**. Pages (`note`, `idea`,
  `project`, `knowledge`, `technical`, `entity`, `concept`, `reference`) linked by typed
  relations. You browse and edit it in the browser; agents read and write it over MCP/REST.
- **Memory** — atomic, deduplicated **facts with trust scores**, shared by every agent.
  What one agent learns, all recall. Written through the Hermes plugin and REST,
  never hand-edited in the UI.

Humans get a wiki. Agents get MCP tools and a REST API. One attribution model: every write
is tied to the API key's actor, server-side.

> [!NOTE]
> Dran does **not** run your agents and keeps **no execution ledger** — no goals, no
> workflow engine, no run history. It is the store they share: knowledge + memory.
> Execution discipline (ledger, briefs, delegation) belongs to the agent's own tooling,
> not here.

## Knowledge

- **8 page types, each with `meta.kind` subtypes and type-specific meta fields** — defined
  in one place, `Dran.PageRegistry` (`lib/dran/page_registry.ex`):

  | Type | Purpose | `meta.kind` values | Extra meta fields |
  |---|---|---|---|
  | `note` | free capture | *(free — none validated)* | `date`, `due_date` |
  | `idea` | sparks & thinking | `idea` `question` `hypothesis` `spark` | — |
  | `project` | work with lifecycle | `project` `plan` `goal` `milestone` | `horizon`, `status`, `due_date` |
  | `knowledge` | captured wisdom | `quote` `summary` `highlight` `excerpt` | `source_url`, `date` |
  | `technical` | code & how-to | `code` `snippet` `debug` `recipe` `config` `command` `template` `pattern` `method` | `language`, `version` |
  | `entity` | named things | `person` `company` `product` `tool` `place` `event` `language` `framework` `hardware` `protocol` | `location`, `external_url` |
  | `concept` | abstract ideas | *(free)* | `domain`, `parent_concept` |
  | `reference` | external sources | `article` `paper` `video` `podcast` `book` `newsletter` `spec` `code` `release` `website` `repo` `api` | `source_url`, `published_at` |

  Every type also accepts `meta.props` (free-form key-value bag, indexed). `meta.kind` is
  validated by the changeset (free on `note`/`concept`); it classifies and filters — it
  never changes behavior. Collections and reports are first-class entities in their own
  tables, not page types.

- **13 relation types** — 5 you set by hand over MCP (`related`, `contradicts`,
  `supersedes`, `part_of`, `embeds`) plus 8 machine-owned, created by Dran and never by
  hand: `semantic` (augmenter), `mentions` (entity linker), `works_in` / `has_tier` /
  `based_in` / `written_in` / `built_with` (props-derived) and `informs` (memory → page,
  at ingest).
- **Props → edges** — `role`, `tier`, `location`, `language`, `framework` auto-materialize
  into typed edges.
- **TipTap markdown editor** — tables, code blocks, mermaid, `![[slug]]` embeds; read-only
  render by default.
- **Version history** with diff view; **machine-owned summaries** (written only by
  API/nightly job).

## Memory

- Atomic facts per workspace, **idempotent on content** (duplicates return the existing
  row); rewordings in the grey zone (cosine 0.88–0.95, typically cross-language) return
  `409 near_duplicate` — refine via `PATCH /api/memory/:id` (trust preserved) or re-add
  with `force=true`.
- **Auto-relations at ingest**: `informs` (memory → top-3 closest pages) and `semantic`
  (memory ↔ related memories, ~0.72–0.88 cosine band) — derived from the dedupe embedding,
  zero extra inference; visible in the 3D graph and as "related facts" in the memory UI.
- **Nightly hygiene**: re-derive edges, sweep edges touching dead memories (both
  endpoints), decay trust of facts that were never retrieved *and* never rated
  (−0.02/30d, floor 0.15; feedback-earned trust never decays).
- **Asymmetric trust**: helpful `+0.05`, unhelpful `−0.10`; search ranks relevance × trust.
- **Ingest efficiency**: the extractor's negative context includes the semantic neighbours
  of the known top-10 (skips related variants, not just dupes); the Hermes plugin sends
  only the session's message delta (cursor per session).
- REST `/api/memory` + a **Hermes plugin** (`hermes_plugin/dran/`): auto-recall at turn
  start, `dran_memory_add/update/search/feedback` tools, auto-capture on session end (facts
  extracted server-side, transcripts never persisted).
- **Not on the MCP surface** — by design.

## The app

- **Wiki** at `/:workspace_slug` — read-first browser: search, type index, pinned pages,
  collections, clusters, graph
- **Memory** `/:ws/memory` · **Reports** `/:ws/reports/:slug`
- **3D graph** (`/:ws/graph`), **clusters** with LLM summaries, **hybrid search**
  (`fts`/`fuzzy`/`semantic`), **smart collections**, activity feed, journey timeline
- **Instance dashboard** at `/`; admin (owner-only) at `/admin`: users, workspaces, models,
  system, jobs
- **Multi-workspace** with per-workspace visibility (public/private) and page-type toggles

## Automation

- **3 workers** — `curator` (duplicate/conflict detection), `link_gardener` (relations for
  orphans), `graph_rag` (GraphRAG Q&A with citations); start over MCP, poll the session
- **7 scheduled jobs** (Quantum cron, toggleable + run-now in admin): curator, PageRank,
  cluster summaries, graph maintenance, link gardener, page summaries, memory re-link
- **Entity linker** — auto-creates entity pages from names detected in bodies

## APIs

**MCP** — `POST /api/mcp`, Streamable HTTP (spec 2025-03-26): **18 tools** for pages,
search, workers and lint; resources (`page://`, `home://`), and the `brainstorm` prompt.
Write tools require a `write_access` key — enforced by a permission-matrix test
(`test/dran/mcp_tool_audit_test.exs`).

**REST** — token-protected `/api/*` (kebab-case): read routes always allowed; writes
(pages, relations, memory) require `write_access: true`. Attribution (`owner`/`created_by`)
is injected server-side from the key's actor — never client-settable.

## Security

- First-run `/setup` creates the owner; Google OAuth optional
- Instance owner + per-workspace roles (`owner` / `admin` / `editor` / `viewer`)
- Per-user API keys, read-only by default (per-workspace `access_level`, default `read`),
  scoped to the creator's workspaces
- Row-level auth on resources; audit tooling in precommit (`sobelow`, `deps.audit`)

## Agent skills

`skills/` ships 5 skills for Hermes (or any skill-loading agent) — one router plus one per
operating flow: `dran` (router), `dran-knowledge-flow`, `dran-relations-flow`,
`dran-workers-flow`, `dran-memory-flow`. Shared rules: one key = one actor; a write is not
done until a readback confirms it; irreversible ops need human confirmation.

## Installation

### 1 · Dran (the server)

**Requirements:** Elixir ~> 1.15, Erlang/OTP 26+, PostgreSQL 14+ with **pgvector**, Node
(asset tooling only).

```bash
git clone git@github.com:alvarolizama/dran.git && cd dran
cp .env.example .env && $EDITOR .env
mix setup && mix phx.server
```

Open [localhost:4000](http://localhost:4000) — first run redirects to `/setup`.

### 2 · Connect an agent (Hermes)

One Dran instance serves every agent. Per agent profile:

**a. Credential.** In Dran → **Settings → Agents**: create the agent and its key, ticking
the **workspace × access-level matrix** (`write` on the workspace that will hold the
agent's memory). The token is shown once. Every write is attributed server-side to this
key's actor.

**b. Secret (once per profile).** Store the token in the profile's `.env` — single source
of truth, shared by MCP and the memory plugin:

```bash
# ~/.hermes/profiles/<profile>/.env
DRAN_API_KEY=<paste-token>
```

**c. MCP server** (18 tools). In the profile's `config.yaml`:

```yaml
mcp_servers:
  dran:
    url: http://localhost:4000/api/mcp
    headers:
      Authorization: Bearer ***
```

**d. Memory plugin** (auto-recall, `dran_memory_*` tools, session ingest). Symlink from
this repo and select it:

```bash
ln -s /path/to/dran/hermes_plugin/dran ~/.hermes/profiles/<profile>/plugins/dran
```

```yaml
memory:
  provider: dran
```

Configure it from the dashboard panel (**Memory → Dran**: base URL, memory workspace,
recall/capture toggles) or `hermes memory setup`. Stored at `$HERMES_HOME/dran/config.json`;
the API key stays in `.env`. The memory workspace must be one the key can reach — the
plugin validates against `GET /api/agent/config` and falls back to the first permitted
workspace (with a warning) if the matrix changes.

**e. Skills** (5: router + knowledge, relations, workers, memory flows). Symlink the suite
into a dir the profile already scans:

```bash
mkdir -p ~/Workspace/Skills
for s in dran dran-knowledge-flow dran-memory-flow \
         dran-relations-flow dran-workers-flow; do
  ln -s /path/to/dran/skills/$s ~/Workspace/Skills/$s
done
```

```yaml
skills:
  external_dirs:
    - ~/Workspace/Skills
```

Restart the Hermes session, then verify: MCP → "list my pages"; memory → "¿qué recuerdas
de …?"; skills → the agent should route Dran questions through the `dran` skill.

Non-Hermes agents: skip d/e, point any MCP client at `POST /api/mcp` with the Bearer key,
or use the REST API directly.

## Configuration

Via environment variables — see [`.env.example`](.env.example) for the full list.
Essentials: `SECRET_KEY_BASE`, `DATABASE_URL`, `PHX_HOST/PORT/SCHEME`, `DRAN_API_TOKEN`,
`DRAN_WORKSPACE_SLUG/NAME`, session salts (prod), `UPLOADS_DIR`. Optional: Google OAuth
vars and `DRAN_INFERENCE_API_URL/KEY` (OpenAI-compatible endpoint powering embeddings,
summaries, workers, semantic search — without it Dran still works, minus those features).

## Production

```bash
MIX_ENV=prod mix deps.get --only prod
MIX_ENV=prod mix compile && MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release   # start with bin/server
```

A `Dockerfile` ships with the repo (Coolify-ready; `/app/bin/migrate` as pre-deploy step).
Runtime env vars only — never bake secrets into the image.

## Tech stack

Phoenix 1.8 + LiveView · PostgreSQL + pgvector · TipTap v3 · MDEx · Tailwind v4 + daisyUI ·
3d-force-graph · Bandit · Quantum · Req · MCP 2025-03-26

## Pre-commit

```bash
mix precommit   # compile --warnings-as-errors → deps.unlock --unused → format → deps audit → sobelow → test
```

## License

MIT
