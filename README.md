# Dran

*Dran* — Tibetan for "remember". What one agent learns, none forget.

**The knowledge base and the toolset your personal AI assistants share**: one
instance holding both the knowledge (a wiki graph) and the memory (facts) that
your assistants read and write. You run it yourself, next to them.

## What it is

One server. One knowledge graph. One memory store. Shared by every agent and
by you.

| | Humans | Agents |
|---|---|---|
| **See it in** | the browser — a wiki with search, graph, timeline | tool calls |
| **Write it via** | the editor | plugin tools, or the REST API directly |
| **Attribution** | your user account | your account token + `X-Hermes-Agent`, resolved server-side |

Two things live inside, and they are different on purpose:

- **Knowledge** — a typed graph of **pages** joined by typed relations.
  Every page has one of the **4 built-in types** (`note`, `entity`, `concept`,
  `reference`) or a **custom type declared by the instance**. Curated,
  editable, versioned. Think "the wiki".
- **Memory** — atomic **facts** with trust scores, deduplicated per owner.
  Written by your assistants as they learn; never hand-edited, always private on
  creation. Think "what your assistants know".

### What it is for

- **One assistant that remembers across sessions** — facts survive restarts,
  and are recalled automatically at the start of a turn.
- **Several assistants that share what they learn** — a fact stored by one is
  available to all, and the graph keeps them linked.
- **Work you drive from either side** — goals, tasks and plans are the same
  rows whether your assistant creates them through a tool or you move them on
  the board.
- **Agent output you can actually read** — reports, notes and entities land
  in a graph you browse, not in a folder of markdown files.
- **Per-item visibility** — every page, memory, collection, report, goal and
  plan is `private` (default), `public`, or `shared` with specific users and
  groups. An API key reads exactly what its owner reads. See
  [Visibility](#visibility).

### Features

**Knowledge**

- **4 built-in page types** (`note`, `reference`, `entity`, `concept`) plus
  **custom types declared by the instance** (own slug, path, icon, color).
  Type-specific meta fields live in one place — `Dran.PageRegistry`. Every page
  also takes `meta.props`, a free-form indexed key-value bag. See
  [docs/page-types.md](docs/page-types.md).
- **13 relation types**: 5 you set by hand (`related`, `contradicts`,
  `supersedes`, `part_of`, `embeds`), 8 machine-owned (`semantic`, `mentions`,
  `works_in`, `has_tier`, `based_in`, `written_in`, `built_with`, `informs`)
  — count: `Dran.Relation.relation_types/0`. Five `meta.props` keys
  auto-materialize into edges.
- **TipTap markdown editor** — tables, code blocks, mermaid, `![[slug]]`
  embeds of your own pages and `![[yt:ID]]` / `![[vimeo:ID]]` / `![[map:q]]`
  third-party embeds (paste a URL, Dran builds the frame — no key, no raw
  HTML). Version history with diff view.
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

**Work**

- **Goals, tasks and plans** — a goal is the WHAT (it derives its progress from
  its tasks), a task is the action (a board with columns, priorities and due
  dates), a plan is the HOW (an ordered checklist). Your assistant creates,
  captures, moves and checks them off through the same tools you click in the UI.
- **Quick capture** — `dran_capture` drops a task into the owner's inbox goal
  with no ceremony; the board is where it lands.
- **Same destinations** — work items take the same per-item visibility
  (`private` | `public` | shared with a group), declared per write.

**Automation**

- **3 background workers**: `curator` (duplicates/conflicts), `link_gardener`
  (relations for orphans), `graph_rag` (Q&A with citations). Start and poll
  them from a tool.
- **7 scheduled jobs** (Quantum cron, toggleable, run-now from `/admin/jobs`; count: `Dran.Jobs`).
- **Entity linker** — auto-creates entity pages from names in page bodies.

**App**

- Wiki at `/` (pages by type, letters, collections); goals at `/goals`, the
  task board at `/tasks`, plans at `/plans`; memory at `/memory`; the 3D graph
  at `/graph`; clusters with LLM summaries at `/clusters`; smart collections
  at `/collections`; reports at `/reports/:slug`; hybrid search at `/search`;
  activity feed at `/activity`; journey timeline at `/journey`.
- Your account and its credential at `/settings/account`; instance
  administration (owner-only) at `/admin`: settings, users, groups, models,
  system, jobs.
- **How to use each surface** — [docs/usage.md](docs/usage.md): pages, custom
  page types, goals, plans and memory, with the destination of every item and
  what an agent can do by tool.

## Stack

| Piece | Version |
|---|---|
| Elixir / Erlang OTP | **1.20.1-otp-29 / 29.0.2** ([`.tool-versions`](.tool-versions); [`mix.exs`](mix.exs) declares `~> 1.15`) |
| Phoenix / LiveView | 1.8 / 1.2 ([`mix.exs`](mix.exs)) |
| Postgres + **pgvector** (Ecto, UUID primary keys) | 14+; the container pins the hexpm Elixir/OTP and Debian pair ([`Dockerfile`](Dockerfile)) |
| UI | Tailwind v4 + daisyUI, one single theme `dim --default` ([`DESIGN.md`](DESIGN.md), §C2) |
| Editor / markdown / graph | TipTap v3 · MDEx · 3d-force-graph ([`assets/package.json`](assets/package.json)) |
| HTTP server · cron · HTTP client | Bandit · Quantum · Req ([`mix.exs`](mix.exs)) |
| Runtime | Mix release in Docker ([`Dockerfile`](Dockerfile)) |

**Versioning:** Semantic Versioning, in [`mix.exs`](mix.exs) (`version:`),
mirrored in [`assets/package.json`](assets/package.json) and
[`hermes_plugin/dran/plugin.yaml`](hermes_plugin/dran/plugin.yaml). The plugin
and the skills ship with the server.

## Local development

**Requirements:** Elixir 1.20+ / Erlang OTP 29, PostgreSQL 14+ with
**pgvector**, Node (asset tooling only — the tailwind/esbuild wrappers download
their own binaries).

```bash
git clone git@github.com:alvarolizama/dran.git && cd dran
cp .env.example .env && $EDITOR .env     # SECRET_KEY_BASE, DATABASE_URL, BOTH salts
mix setup                                # deps.get → ecto.create → ecto.migrate → assets → seed
mix phx.server                           # http://localhost:4000
```

Open [localhost:4000](http://localhost:4000) — first run redirects to `/setup`
to create the owner account. **The instance IS the workspace** — everything
lives in one place. Your API credential lives in **Settings → Account**
(Profile): copy or regenerate `users.api_token` there.

`GET /health` answers `200` without touching the database: it is the container's
probe, not a readiness check (see [Production](#production)).

### The Hermes plugin

Gives an agent the tools (`dran_*`, 46) **and** the memory provider
(`dran_memory_*`, 4) — 50 in total — one token, one attribution, its owner's
reach.

**a. Create the credential.** In Dran → **Settings → Account** (Profile):
copy your API token (`users.api_token` — shown in full; regenerate there when
you need to rotate it). There are no per-agent keys and no access levels to
pick: the token reads and writes exactly what its owner can read. Every write
is attributed server-side to the account (or to the `X-Hermes-Agent` header
when the client sends one).

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
  "workspace": "personal",  // deprecated — informational only
  "auto_recall": true,
  "auto_capture": true,
  "max_recall_results": 5,
  "max_recall_chars": 800,
  "recall_cadence": 1
}
```

> **`workspace` is deprecated (informational only).** Dran is single-instance:
> the instance IS the workspace and every call targets it regardless of this
> value. The setting stays so existing config files keep loading.

**e. Restart the session** and verify: ask it to *"list my pages"* (tools) and
*"what do you remember about…"* (memory).

### The skills

One suite, versioned with this repo. Install it:

```bash
mkdir -p ~/Workspace/Skills
for s in dran dran-knowledge-flow dran-memory-flow \
         dran-relations-flow dran-workers-flow dran-goal-flow \
         dran-plan-flow dran-services-flow dran-skills-flow; do
  ln -sfn /path/to/dran/skills/$s ~/Workspace/Skills/$s
done
```

```yaml
# config.yaml
skills:
  external_dirs:
    - ~/Workspace/Skills
```

Full details — the 60-char description limit, the naming convention, why
`external_dirs` and not the plugin's `register_skill` — in
[skills/README.md](skills/README.md).

> **These are the LOCAL suite (the skills that teach an agent to operate Dran).
> A Dran instance can also SERVE skills of its own** — instructions written in
> the web UI (`/skills`), with their own per-item read scope, that any agent with
> an API key lists with `dran_skills` and loads with `dran_skill`. Those live ONLY
> in Dran: no file on disk, no anonymous index, and the body dies with the
> session.

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
  pages, typed relations, memories, its workers, the user's own connected
  services, the work surface: goals, tasks and plans, or the skills the instance
  serves to agents), load the `dran` skill and whichever apply:
  `dran-knowledge-flow` (pages), `dran-relations-flow` (typed links),
  `dran-memory-flow` (durable facts), `dran-workers-flow`
  (curator / link_gardener / graph_rag), `dran-services-flow` (the user's apps:
  connect and run), `dran-goal-flow` (goals · tasks · destination),
  `dran-plan-flow` (plans · checklist), `dran-skills-flow` — **the Dran skills
  are REMOTE**: list them with `dran_skills` and follow the one that applies with
  `dran_skill`; nothing is copied to disk. Dran stores and returns what is
  known — it does not decide it.
```

Keep it that short: the prompt references the skills, it never embeds them.
The same block lives at [`system-prompt.md`](system-prompt.md).

## Configuration

Every variable with its comment and its safe default is in
[`.env.example`](.env.example). Two blocks matter:

- **Required in production** — `DATABASE_URL`, `SECRET_KEY_BASE`, `PHX_HOST`,
  `SESSION_SIGNING_SALT`, `SESSION_ENCRYPTION_SALT`: the boot **raises** without
  them, by design, and the two salts must differ from each other.
- **Optional commons** — `PORT`, `PHX_SCHEME`, `PHX_PORT`, `POOL_SIZE`,
  `ECTO_SSL`, `SESSION_MAX_AGE_SECONDS`, `CHECK_ORIGINS` and the rest,
  documented in the same file.

Dran's own variables, alongside those:

| Variable | What it does |
|---|---|
| `UPLOADS_DIR` | where uploads are stored (default `priv/static/uploads`) — mount a volume there in production |
| `UPLOADS_MAX_SIZE` | max upload size in bytes (default 100 MiB) |
| `DRAN_INFERENCE_API_URL` / `_API_KEY` | any OpenAI-compatible endpoint; powers embeddings, summaries, semantic search and the workers — without it Dran still works, minus those features |
| `DRAN_COMPOSIO_API_KEY` / `_BASE_URL` | scoped Composio project key for the **services** surface (`/services`, `/api/services`, the agent's services tools). Instance state, server-side only — it is never shown in the UI (only its state) and never reaches a client. Unset = the whole surface is off and answers fail-closed |
| `WORKER_MAX_STEPS` / `WORKER_PER_STEP_TIMEOUT` | worker step budget |
| `SKIP_MIGRATIONS` / `DRAN_RESET` | entrypoint switches (see [Production](#production)) |

> Against a local Postgres **without TLS** you must pass `ECTO_SSL=false`: the
> default is SSL on (for managed databases) and the symptom is misleading
> (`ssl not available` plus `failed to create db … "killed"`).

Not env vars (stored in the database, edited in the UI): the default workspace
resolves automatically (single instance); the legacy
admin API token lives in `/admin/system`; per-user tokens in
`/admin/users`; keys are personal (per-user, `/settings/api-keys`).

## The UI standard

[`DESIGN.md`](DESIGN.md) is the family's **Commons** (theme and tokens, layout,
elements, cards, tables, modals, pickers, charts, states, shell) copied as-is,
plus `## Custom — Dran` with what is exclusive to Dran. The Commons is edited in
the family's boilerplate repo and propagates by copying — **never edited here**.
To check that it still matches byte-exactly:

```bash
bash ../boilerplate/skeleton/check-commons.sh .   # -> OK (byte-exact)
```

## Production

```bash
docker build -t dran .
docker run --rm -p 4000:4000 --env-file .env dran
```

A multi-stage [`Dockerfile`](Dockerfile) ships with the repo: prebuilt hexpm
Elixir image → slim Debian runtime, non-root `app` user, listen port `4000`,
migrations before serving. Runtime env vars only — never bake secrets into the
image. To build the release by hand instead:

```bash
rm -rf _build/prod && MIX_ENV=prod mix deps.get --only prod
MIX_ENV=prod mix compile && MIX_ENV=prod mix release   # start with bin/server
```

| Piece | What to respect |
|---|---|
| **Ports** | `PORT` (the real listen) must match the platform's **Ports Exposes**; `PHX_PORT` is only the port used in generated URLs (443 with TLS). `EXPOSE` does not change the listen, which is why the image does not use it |
| **Healthcheck** | the image ships a `HEALTHCHECK` on **`GET /health`** — a bare `200` that touches no database, so it passes while the boot warms the connection pool. Point the proxy at `/health` expecting 200, **never at `/`**: `/` redirects to `/login` (302) and a proxy configured for 200 reports a healthy container as down → 502. Mind the window before the listener exists: the entrypoint migrates first, so a proxy that gives up sooner will 502 during a deploy |
| **Migrations** | the entrypoint runs `Dran.Release.setup/0` (create → migrate → seed the instance row) on **every** deploy, before serving. A failed migration aborts the boot and the deploy rolls back. `SKIP_MIGRATIONS=1` skips it (one-off task containers) |
| **First account** | the boot creates **nobody**: the first visitor gets the `/setup` screen, and whoever arrives first claims the instance as owner. Claim it yourself right after the first deploy, or keep the instance behind a network boundary — there is no `DRAN_ADMIN_*` variable to pre-create it with, and never a fallback account or password in this repository |
| **HTTPS** | `force_ssl` is **compile-time**: behind a VPN with no TLS terminator, build with `--build-arg DISABLE_FORCE_SSL=1` **and** run with `PHX_SCHEME=http` |
| **Uploads** | Dran stores uploads, so mount a persistent volume at `UPLOADS_DIR`. The directory is in `.dockerignore` — being in `.gitignore` is not enough, the build context is a different thing, and `COPY priv priv` would bake local uploads into the image |
| **Reset** | `DRAN_RESET=1` is **destructive**: it drops the whole schema (every workspace with its content, every user, key and setting) and rebuilds it empty, leaving the instance at `/setup`. It runs on **every** container start while it is set — unset it as soon as the first boot finishes |

No account is ever seeded by a release: `Dran.Release.setup/0` seeds the
instance row only, the owner is born in the first-run `/setup` screen, and
`Dran.Release.seed_demo/0` refuses to run outside dev.

## Tests and gates

```bash
mix precommit   # compile --warnings-as-errors → deps.unlock --unused → format → deps.audit → sobelow → test
```

A green `precommit` does not cover the `:prod` config, so verify the release too:

```bash
DATABASE_URL=ecto://nope:nope@127.0.0.1:1/nope SECRET_KEY_BASE=test \
  PHX_HOST=localhost SESSION_SIGNING_SALT=a SESSION_ENCRYPTION_SALT=b \
  _build/prod/rel/dran/bin/dran eval "IO.puts(:ok)"     # -> :ok
```

## Documentation

- **Usage** — [docs/usage.md](docs/usage.md) — the surfaces, the destination and the tools
- **REST API** — [docs/api.md](docs/api.md)
- **Page types** — [docs/page-types.md](docs/page-types.md)
- **Security review** — [docs/security-review.md](docs/security-review.md)
- **Dependency debt** — [docs/dependency-debt.md](docs/dependency-debt.md)
- **Plugin** — [hermes_plugin/dran/README.md](hermes_plugin/dran/README.md)
- **Skills** — [skills/README.md](skills/README.md)
- **UI standard** — [DESIGN.md](DESIGN.md)
- **History** — [docs/archive/](docs/archive/) — superseded analyses, kept as
  provenance (read-only)

## Architecture

```
┌──────────────┐   plugin tools (50)   ┌──────────────────┐
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

### Services (the user's own apps)

`/services` (and `/api/services`) is where a person connects THEIR apps — Gmail,
calendar, GitHub, Slack… — and their agent uses them. The shape:

- **One instance key, one user credential.** Composio is reached with the
  instance's scoped project key (`DRAN_COMPOSIO_API_KEY`, server-side only); the
  reader is identified by the credential that already exists, so `N` agents with
  the same key are the same reader.
- **The instance decides what is exposed** (owner's allowlist in Instance
  settings) and **the user decides what to connect**: a service outside the
  allowlist cannot be listed, catalogued or executed, and only the owner of a
  connection runs against it.
- **The state is a lifecycle, read from the server** (`INITIALIZING` →
  `INITIATED` → `ACTIVE` / `EXPIRED`; `INACTIVE` does not run tools). The
  callback after the provider's consent carries no authority: the state is
  re-read, never believed.
- **dran sits in the middle of every call** (allowlist gate, state gate, and a
  row in `service_calls` with the tool, the agent and the provider's `log_id`),
  which is why the vocabulary is connect / reconnect / disconnect — no pause —
  and why disconnecting *deletes* with an upstream revocation.
- **The catalog travels as data.** The agent has five fixed service tools; the
  toolkit's tools are discovered by query, so the number of tools never grows
  with the number of services.

### Security

- First-run `/setup` creates the owner; Google OAuth optional
- Instance owner + instance roles (`owner` / `admin` / `editor` / `viewer`)
- One credential per account (`users.api_token`, copy/regenerate in
  **Settings → Account**): it reads and writes exactly as its owner
- Per-item visibility: every page/memory/collection/report/goal/plan is
  `private` (default), `public`, or `shared` with users and groups; the read
  filter is one module (`Dran.ContentVisibility`)
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
- **Goals and plans** declare their destination per WRITE (`scope: private |
  public | %{group: slug}`); a task inherits its goal's visibility — that is
  why sharing the goal is enough.
- **Memories** are always created `private` by tools/API; visibility changes
  happen only in the web UI (a `visibility` param returns 422).

## License

Released under the [MIT License](LICENSE) — Copyright (c) 2026 Álvaro Lizama.
The license covers the whole repository: the Elixir/Phoenix server, the Hermes
plugin (`hermes_plugin/dran/`), and the agent skills (`skills/`).
Third-party dependencies keep their own licenses; vendored assets
(`assets/vendor/daisyui`) are subject to their upstream licenses (daisyUI — MIT).