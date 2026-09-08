<div align="center">

# 🧠 Dran

### Knowledge base & memory for AI agents — with a built-in execution ledger

A personal/shared second brain built with **Phoenix 1.8 + LiveView**, designed to be operated by humans **and** AI agents. Your knowledge lives as **typed pages** connected by **typed relations**, forming a queryable knowledge graph. Agents read and write it through **MCP** and a **REST API**, share a **trust-weighted memory**, and leave **verifiable execution evidence** in workflow runs — the ledger.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Elixir](https://img.shields.io/badge/Elixir-1.15+-4B275F?logo=elixir&logoColor=white)](https://elixir-lang.org)
[![Phoenix](https://img.shields.io/badge/Phoenix-1.8-LiveView-FD4F00?logo=phoenixframework&logoColor=white)](https://www.phoenixframework.org)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-pgvector-336791?logo=postgresql&logoColor=white)](https://www.postgresql.org)
[![MCP](https://img.shields.io/badge/MCP-Server-5B8DEF?logo=modelcontextprotocol&logoColor=white)](https://modelcontextprotocol.io)

![Dran](docs/dran-header.png)

</div>

## The three planes

Dran is not a note app with an API bolted on. It is a single system with three interlocking planes:

| Plane | What it holds | Surface |
| --- | --- | --- |
| **Knowledge** | Typed pages + typed relations — the queryable graph | Wiki UI, MCP tools, REST |
| **Memory** | Atomic, deduplicated, trust-weighted facts shared by every agent | REST `/api/memory`, Hermes plugin |
| **Ledger** | Workflow runs: what an agent claimed, what was verified, when | MCP run lifecycle, `/:ws/workflows` |

An agent that only reads pages is using a third of Dran. The full loop is: recall from memory → read/create knowledge → execute a workflow → close runs with verified claims → let the nightly workers curate the graph.

## Knowledge

- **4 page types** — `note`, `entity`, `concept`, `reference` — each a full citizen (graph, journey, embeddings, MCP-create). Goals, collections and reports are first-class entities in their own tables, not page types
- **TipTap markdown editor** — WYSIWYG with tables, code blocks, mermaid diagrams and `![[slug]]` page embeds; pages render read-only by default, *Edit* opens the editor
- **13 relation types** — `related`, `part_of`, `supersedes`, `contradicts`, `embeds`, `semantic`, `mentions`, `works_in`, `has_tier`, `based_in`, `written_in`, `built_with`, `depends_on` — link pages freely, no rigid hierarchy, orphans are fine
- **Custom props → graph edges** — five prop keys (`role`, `tier`, `location`, `language`, `framework`) auto-materialize into typed edges to entity/concept pages
- **Version history** — every edit is versioned, with diff view on the page detail
- **Machine-owned summaries** — the page `summary` is written only by MCP/API and the nightly job, never by hand

## Workflows — the execution ledger

- **Workflows are DAGs** — steps with `depends_on`, authored in a visual canvas editor or over the API
- **Step = contract** — each step declares intent, pre-registered claims and gates: *what must be true when this step is done*. The contract is pure data; the server enforces readiness and cycle rules
- **Sessions & runs** — `open session → claim run (start) → report progress (✓NN) → close with outcome`; retry re-opens a failed run. Passed gates render as checked nodes in the DAG
- **Pending-run queue** — agents pull their next ready step via MCP (`dran_list_pending_runs`); row-level auth and locks keep two agents from claiming the same run
- **Runs are evidence, not vibes** — a run closed without re-running its gates is a false checkpoint; the UI shows what was actually verified

### Riel

Dran is the **board**; Riel is the **discipline**. Riel (the agent-side execution protocol — ledger, briefs, delegation) runs locally in the agent; Dran declares **what to verify** (step contracts) and stores the **durable evidence** (runs). The `skills/dran-workflow-flow` skill executes the Riel cycle over Dran's MCP tools — Dran never imposes Riel, but its run ledger is designed to be the remote half of it. Runs are the only Riel ledger in Dran: memory and goal checklists are deliberately outside this loop.

## Goals

- **First-class entities** (own table, own UI at `/:ws/goals`) with measurable targets, archived state and linked workflows ("Workflows vinculados")
- **Human-managed checklist** — the goal checklist is the owner's OKR, not agent scratch space; agents can add/toggle items over MCP but the plan of record is human
- Goals link optionally to workflows via FK — progress rolls up from run outcomes

## Memory — shared multi-agent recall

- **Atomic facts per workspace** — exact, immutable content; no LLM augmentation rewrites a memory
- **Content dedupe** — `add` is idempotent per workspace; duplicates return the existing row untouched
- **Asymmetric trust** — helpful `+0.05`, unhelpful `−0.10`, clamped `[0,1]`; search multiplies relevance by trust so useful facts surface first
- **Hybrid search** — full-text + embeddings over the shared store (`GET /api/memory/search`)
- **Hermes plugin** (`hermes_plugin/dran/`) — auto-recall at turn start (background prefetch), `dran_memory_add/search/feedback` tools, and auto-capture on session end (facts extracted server-side; transcripts are never persisted). One API key per agent → `created_by` attribution is server-side; subagents get read-only memory
- **Not in the MCP surface** — memory is REST + plugin only, by design

## Views

- **Wiki at the workspace root** (`/:workspace_slug`) — read-first knowledge browser: sidebar with search, type index, pinned pages, collections, clusters, graph
- **Instance dashboard** (`/`) — workspaces + metrics for every logged-in user; admin at `/admin` (owner-only): users, workspaces, models, system, jobs, impersonation
- **Workflows** (`/:ws/workflows`) — index/board with kind & status filters, DAG detail with run state
- **Goals** (`/:ws/goals`), **Memory** (`/:ws/memory`), **Reports** (`/:ws/reports/:slug`)
- **3D knowledge graph** (`/:ws/graph`) — force-directed; hover highlights neighbors, click navigates
- **Clusters** (`/:ws/clusters`) — modularity-detected clusters with LLM-generated summaries (nightly or on demand)
- **Hybrid search** (`/:ws/search`) — full-text, fuzzy, semantic or fused, with optional rerank
- **Smart Collections** (`/:ws/collections`) — saved live queries rendered as pages
- **Activity feed**, **Journey** timeline, **per-workspace settings** (page types, features)
- **Multi-workspace** — switch brains from the sidebar; per-workspace visibility (`public`/`private`) and page-type toggles

## Automation

- **3 autonomous workers** — `curator` (duplicate/conflict detection via embeddings → report), `link_gardener` (proposes relations for orphan pages), `graph_rag` (GraphRAG Q&A with citations). Start over MCP (`dran_start_worker`) and poll the session
- **6 scheduled jobs** (Quantum cron, toggleable + "run now" from the admin jobs panel): `curator_daily`, `pagerank_nightly`, `cluster_summaries_nightly`, `graph_maintenance_nightly`, `link_gardener_weekly`, `page_summaries_nightly` — each run writes a `report` page
- **Entity linker** — auto-creates entity pages from real-world names detected in bodies (noise-filtered, toggleable)
- **Graph intelligence** — PageRank authority scoring, cluster detection, maintenance sweeps

## MCP server

`POST /api/mcp` — Streamable HTTP (MCP spec 2025-03-26), token-authenticated.

- **35 tools** — pages & notes CRUD, search (`full`/`fuzzy`/`semantic`/`hybrid`), links & stats, goals CRUD + checklist ops, workflows/sessions/runs lifecycle (`get_workflow`, `get_step_contract`, `open_workflow_session`, `list_pending_runs`, `start_run`, `report_run_progress`, `close_run`, `retry_run`), workers, `lint_brain`, `rename_slug`, `reaugment_page`
- **22 write tools** are gated behind `write_access: true` on the API key — read-only keys get `403` on every one of them (enforced by a permission-matrix test: a new write tool without a matrix row fails the audit)
- **3 resources** — `page://{ws}/{slug}`, `goal://{ws}/{slug}`, `home://{ws}/index`
- **2 prompts** — `brainstorm`, `goal_review`
- **Attribution is server-side** — `owner`/`created_by` and run claims derive from the key's actor; never client-settable

## REST API

Token-protected CRUD under `/api/*` (kebab-case routes, tables prefixed by domain):

- **Read** — workspaces, knowledge-pages (+ links, graph), search (full/fuzzy/semantic), goals, index, log, lint, memory (list/search), workflow sessions, pending runs, export
- **Write** (requires `write_access: true`) — workspaces/pages/relations CRUD, workflow session + run lifecycle (`open`, `start`, `progress`, `close`, `retry`), memory (`create`, `feedback`, `ingest`, `delete`)
- Owner/created_by injected from the auth identity on every create

## Security

- **First-run `/setup`** creates the owner account; Google OAuth optional (invite/domain-restricted)
- **Instance + workspace roles** — `is_owner` (instance admin at `/admin`), per-workspace `owner`/`admin`/`editor`/`viewer`; workspace routes gated by members ∪ public ∪ owner; settings by workspace admin
- **Per-user API keys** — scoped to the key creator's workspaces, `write_access` toggle (read-only by default), role inherited from creator
- **Row-level auth** on executions (LiveView + API), IDOR-hardened task/relation paths, `FOR UPDATE` locks on run claim/close/reopen, UUID guards
- **Audit tooling in precommit** — `deps.audit` + `sobelow --exit medium`

## Agent skills suite

`skills/` ships a 7-skill suite for Hermes (or any skill-loading agent) that encodes the operating flows above:

`dran` (router) · `dran-knowledge-flow` · `dran-relations-flow` · `dran-goals-flow` · `dran-workflow-flow` (Riel loop) · `dran-workers-flow` · `dran-memory-flow`

Shared rules across the suite: one key = one actor; a write is not done until a readback confirms the state; irreversible operations require explicit human confirmation.

## Installation

**Requirements:** Elixir ~> 1.15, Erlang/OTP 26+, PostgreSQL 14+ with the **pgvector** extension, Node (only for asset tooling, handled by `esbuild`/`tailwind` installers).

```bash
git clone git@github.com:alvarolizama/dran.git && cd dran
cp .env.example .env && $EDITOR .env   # fill in the values below
mix setup        # deps → DB create → migrations → assets → seed
mix phx.server
```

Open [localhost:4000](http://localhost:4000) — first run redirects to `/setup` to create the owner account.

## Configuration

All configuration is via environment variables — see [`.env.example`](.env.example) for the full annotated list. The essentials:

| Variable | Purpose |
| --- | --- |
| `SECRET_KEY_BASE` | Session signing — generate with `mix phx.gen.secret` |
| `DATABASE_URL` | Ecto URL, e.g. `ecto://postgres:postgres@localhost/dran_dev` |
| `PHX_HOST` / `PHX_PORT` / `PHX_SCHEME` | Public host/port/scheme for URL generation |
| `DRAN_API_TOKEN` | Legacy admin bearer token for REST/MCP |
| `DRAN_WORKSPACE_SLUG` / `DRAN_WORKSPACE_NAME` | Default workspace created on seed |
| `GOOGLE_OAUTH_CLIENT_ID` / `GOOGLE_OAUTH_CLIENT_SECRET` | Optional — enables "Sign in with Google" |
| `DRAN_INFERENCE_API_URL` / `DRAN_INFERENCE_API_KEY` | OpenAI-compatible inference endpoint (`/v1/embeddings`, `/v1/rerank`, `/v1/chat/completions`) — powers embeddings, summaries, workers, semantic search |
| `SESSION_SIGNING_SALT` / `SESSION_ENCRYPTION_SALT` | Required in production (`mix phx.gen.secret 32`) |
| `UPLOADS_DIR` | File upload storage path |
| `DISABLE_FORCE_SSL` | Set to `1` **at build time** when serving over plain HTTP (VPN tunnels) |

Inference is optional: without it, Dran still works — you lose embeddings, semantic search, auto-summaries, and workers.

## Production

```bash
MIX_ENV=prod mix deps.get --only prod
MIX_ENV=prod mix compile
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release   # start with bin/server
```

A `Dockerfile` ships with the repo (Coolify-ready; `/app/bin/migrate` runs migrations as a pre-deploy step). Runtime env vars only — never bake secrets into the image.

## Tech stack

Phoenix 1.8 + LiveView · PostgreSQL + pgvector · TipTap v3 · MDEx (comrak) · Tailwind v4 + daisyUI · 3d-force-graph (three.js) · Bandit · Quantum (cron) · Req · MCP 2025-03-26

## Pre-commit

```bash
mix precommit   # compile --warnings-as-errors → deps.unlock --unused → format → deps audit → sobelow → test
```

## License

MIT
