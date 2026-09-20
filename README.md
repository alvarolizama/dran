# Dran

*Dran* — Tibetan for "remember". What one agent learns, none forget.

**A shared brain for agent swarms**: one instance holding both the knowledge
(a wiki graph) and the memory (facts) that every agent reads and writes.

## What is Dran

One server. One knowledge graph. One memory store. Shared by every agent and
by you.

| | Humans | Agents |
|---|---|---|
| **See it in** | the browser — a wiki with search, graph, timeline | tool calls |
| **Write it via** | the editor | plugin tools, or the REST API directly |
| **Attribution** | your user account | the API key + `X-Hermes-Agent`, resolved server-side |

Two things live inside, and they are different on purpose:

- **Knowledge** — a typed graph of **pages** joined by typed relations.
  Every page has one of the **4 built-in types** (`note`, `entity`, `concept`,
  `reference`) or a **custom type declared by the instance**. Curated,
  editable, versioned. Think "the wiki".
- **Memory** — atomic **facts** with trust scores, deduplicated per owner.
  Written by agents as they learn; never hand-edited, always private on
  creation. Think "what the swarm knows".

## What it is for

- **One agent that remembers across sessions** — facts survive restarts, and
  are recalled automatically at the start of a turn.
- **Many agents that share what they learn** — a fact stored by one is
  available to all; the graph keeps them linked.
- **Agent output you can actually read** — reports, notes and entities land
  in a graph you browse, not in a folder of markdown files.
- **Per-item visibility** — every page, memory, collection and report is
  `private` (default), `public`, or `shared` with specific users and groups.
  An API key reads exactly what its owner reads. See
  [Visibility](#visibility).

## Features

**Knowledge**
- **4 built-in page types** (`note`, `reference`, `entity`, `concept`) plus
  **custom types declared by the instance** (own slug, path, icon, color). Type-specific meta fields live in one place —
  `Dran.PageRegistry`. Every page also takes `meta.props`, a free-form indexed
  key-value bag. See [docs/page-types.md](docs/page-types.md).
- **13 relation types**: 5 you set by hand (`related`, `contradicts`,
  `supersedes`, `part_of`, `embeds`), 8 machine-owned (`semantic`, `mentions`,
  `works_in`, `has_tier`, `based_in`, `written_in`, `built_with`, `informs`).
  Five `meta.props` keys auto-materialize into edges.
- **TipTap markdown editor** — tables, code blocks, mermaid, `![[slug]]`
  embeds. Version history with diff view.
- **Hybrid search** — full-text, fuzzy and semantic, fused.

**Memory**
- **Idempotent on content**: re-storing a fact returns the existing row. A
  grey-zone rewording (cosine 0.88–0.95, typically cross-language) returns
  `409 near_duplicate` so nothing is silently merged.
- **Asymmetric trust**: helpful `+0.05`, unhelpful `−0.10`; ranking is
  relevance × trust. Untouched, never-rated facts decay slowly.
- **Auto-relations at ingest**: facts link to their closest pages and to
  sibling facts, for free (derived from the dedupe embedding).
- **Auto-recall and auto-capture** through the plugin: relevant facts are
  injected at turn start, and the session is digested at the end (facts
  extracted server-side — the transcript is never stored).

**Automation**
- **3 background workers**: `curator` (duplicates/conflicts), `link_gardener`
  (relations for orphans), `graph_rag` (Q&A with citations). Start and poll
  them from a tool.
- **7 scheduled jobs** (Quantum cron, toggleable, run-now from `/admin`).
- **Entity linker** — auto-creates entity pages from names in page bodies.

**App**
- Wiki at `/`; memory at `/memory`; 3D graph at
  `/:ws/graph`; clusters with LLM summaries; smart collections; activity feed;
  journey timeline.
- Admin (owner-only) at `/admin`: users, groups, models, system, jobs.

## Architecture

```
┌──────────────┐   plugin tools (21)   ┌──────────────────┐
│ Hermes agent │ ────────────────────► │                  │
└──────────────┘                       │   Dran server    │
┌──────────────┐   REST /api/*         │   (Phoenix)      │
│ any agent    │ ────────────────────► │                  │
└──────────────┘                       │  Postgres +      │
┌──────────────┐      browser          │  pgvector        │
│   you        │ ────────────────────► │                  │
└──────────────┘                       └──────────────────┘
```

There is **no MCP server**. The agent surface is the Hermes plugin, and every
tool it exposes is a thin client over the REST API — so a non-Hermes agent
uses the same routes directly.

## Install

Three parts, independent: **the server**, **the plugin**, **the skills**.

### 1 · The server

**Requirements:** Elixir 1.20+, Erlang/OTP 26+, PostgreSQL 14+ with
**pgvector**, Node (asset tooling only).

```bash
git clone git@github.com:alvarolizama/dran.git && cd dran
cp .env.example .env && $EDITOR .env
mix setup && mix phx.server
```

Open [localhost:4000](http://localhost:4000) — first run redirects to `/setup`
to create the owner account. The instance IS the workspace — everything
lives in one place. Manage types and features in **Settings →
API Keys**, an API key (see below).

**Configuration:** environment variables — [`.env.example`](.env.example) has the
full list. Essentials: `SECRET_KEY_BASE`, `DATABASE_URL`, `PHX_HOST/PORT/SCHEME`,
`UPLOADS_DIR`. Optional: `DRAN_INFERENCE_API_URL/KEY` (any OpenAI-compatible
endpoint; powers embeddings, summaries, semantic search and the workers —
without it Dran still works, minus those features).

Not env vars (stored in the database, edited in the UI): the default workspace
resolves automatically (single instance); the legacy
admin API token lives in `/admin/system`; per-user tokens in
`/admin/users`; keys are personal (per-user, `/settings/api-keys`).

### 2 · The Hermes plugin

Gives an agent the tools (`dran_*`, 17) **and** the memory provider
(`dran_memory_*`, 4) — one key, one attribution, its owner's reach.

**a. Create the credential.** In Dran → **Settings → API Keys**: create the key
and pick its access level (`read` | `write` — a key reads and writes with
exactly its owner's reach). The token is shown once. A key
creates no actor: every write is attributed server-side to the key (or to the
`X-Hermes-Agent` header when the client sends one).

**b. Store the secret** in the profile's `.env` — single source of truth,
shared by the tools and the memory provider:

```bash
# ~/.hermes/profiles/<profile>/.env
DRAN_API_KEY=<paste-token>
```

**c. Symlink the plugin and enable it:**

```bash
ln -sfn /path/to/dran/hermes_plugin/dran ~/.hermes/profiles/<profile>/plugins/dran
```

```yaml
# ~/.hermes/profiles/<profile>/config.yaml
plugins:
  enabled:
    - dran
memory:
  provider: dran
```

**d. Configure it.** Values live in `$HERMES_HOME/dran/config.json`; the API key
stays in `.env`. Either:

- the desktop panel — **Memory → Dran** (base URL, recall/capture
  toggles), or
- `hermes memory setup dran` (terminal, same fields), or
- edit the JSON directly:

```json
{
  "base_url": "http://localhost:4000",
  "workspace": "personal",  # deprecated — informational only
  "auto_recall": true,
  "auto_capture": true,
  "max_recall_results": 5,
  "max_recall_chars": 800,
  "recall_cadence": 1
}
```

> **`workspace` is deprecated (informational only).** Dran is single-workspace:
> the instance IS the workspace and every call targets it regardless of this
> value. The setting stays so existing config files keep loading.

**e. Restart the session** and verify: ask it to *"list my pages"* (tools) and
*"what do you remember about…"* (memory).

### 3 · The skills

Two suites, versioned with this repo. Install the daily ones:

```bash
mkdir -p ~/Workspace/Skills
for s in dran dran-knowledge-flow dran-memory-flow \
         dran-relations-flow dran-workers-flow; do
  ln -sfn /path/to/dran/skills/$s ~/Workspace/Skills/$s
done
```

```yaml
# config.yaml
skills:
  external_dirs:
    - ~/Workspace/Skills
```

Add `skills/dev/dran-dev-*` too if you also work on this repo's code. Full
details — the 60-char description limit, the naming convention, why
`external_dirs` and not the plugin's `register_skill` — in
[skills/README.md](skills/README.md).

Then point the agent at them from its system prompt:

```
## Frameworks — activation lines

- **Riel (steering)** — when opening or maintaining any LLM conversation or
  task, load `riel-protocol` and whichever apply: `riel-ledger` (state for
  multi-phase work), `riel-contract` (the plan as a mermaid DAG),
  `riel-briefs` / `riel-delegate` (delegation packets), `riel-cli` (drive the
  ledger and instantiate packets with `rielctl`). Riel creates no capability —
  it stops capability from being lost.
- **Dran (second brain)** — when operating the Dran workspace (knowledge
  pages, typed relations, memories, or its workers), load the `dran` skill
  and whichever apply: `dran-knowledge-flow` (pages), `dran-relations-flow`
  (typed links), `dran-memory-flow` (durable facts), `dran-workers-flow`
  (curator / link_gardener / graph_rag). Dran stores and returns what is
  known — it does not decide it.
```

Keep it that short: the prompt references the skills, it never embeds them.
The same block lives at [`system-prompt.md`](system-prompt.md).

## Reference

- **REST API** — [docs/api.md](docs/api.md)
- **Page types** — [docs/page-types.md](docs/page-types.md)
- **Plugin** — [hermes_plugin/dran/README.md](hermes_plugin/dran/README.md)
- **Skills** — [skills/README.md](skills/README.md)

### Security

- First-run `/setup` creates the owner; Google OAuth optional
- Instance owner + instance roles (`owner` / `admin` / `editor` / `viewer`)
- Per-user API keys (`read` | `write`): a key reads and writes exactly as its
  owner
- Per-item visibility: every page/memory/collection/report is `private`
  (default), `public`, or `shared` with users and groups; the read filter is
  one module (`Dran.ContentVisibility`)
- Memory visibility is web-only: tools/API create private facts and a
  `visibility` param is rejected with 422
- Row-level auth on resources; `sobelow` + `deps.audit` in precommit

### Visibility

The instance is one workspace; isolation lives on the ITEM:

| Value | Who reads it |
|---|---|
| `private` (default) | its owner and instance admins |
| `public` | every user of the instance |
| `shared` | the owner, admins, and the users/groups holding a share grant |

- **Share grants** (read-only) are managed from the web UI — the Share dialog
  on any page, and user groups from `/admin/groups`.
- **Pages** may set `visibility` at creation via the API/plugin
  (`dran_create_page(visibility: "public")`).
- **Memories** are always created `private` by tools/API; visibility changes
  happen only in the web UI (a `visibility` param returns 422).

### Production

```bash
MIX_ENV=prod mix deps.get --only prod
MIX_ENV=prod mix compile && MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release   # start with bin/server
```

A `Dockerfile` ships with the repo (Coolify-ready; `/app/bin/migrate` as the
pre-deploy step). Runtime env vars only — never bake secrets into the image.

### Development

```bash
mix precommit   # compile --warnings-as-errors → deps.unlock → format → deps.audit → sobelow → test
```

**Stack:** Phoenix 1.8 + LiveView · PostgreSQL + pgvector · TipTap v3 · MDEx ·
Tailwind v4 + daisyUI · 3d-force-graph · Bandit · Quantum · Req

**Versioning:** Semantic Versioning, in [`mix.exs`](mix.exs) (`version:`),
mirrored in `assets/package.json` and `hermes_plugin/dran/plugin.yaml`. The
plugin and the skills ship with the server.

## License

Released under the [MIT License](LICENSE) — Copyright (c) 2026 Álvaro Lizama.
The license covers the whole repository: the Elixir/Phoenix server, the Hermes
plugin (`hermes_plugin/dran/`), and the agent skills (`skills/`).
Third-party dependencies keep their own licenses; vendored assets
(`assets/vendor/daisyui`) are subject to their upstream licenses (daisyUI — MIT).
