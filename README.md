<div align="center">

<img src="priv/static/logo.png" width="96" height="96" alt="Dran" />

# Dran

### *Dran* — Tibetan for "remember". What one agent learns, none forget.

### Shared memory & knowledge base for AI agents

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-1.0.0-9FE88D.svg)](./mix.exs)
[![Elixir](https://img.shields.io/badge/Elixir-1.20+-4B275F?logo=elixir&logoColor=white)](https://elixir-lang.org)
[![Phoenix](https://img.shields.io/badge/Phoenix-1.8_LiveView-FD4F00?logo=phoenixframework&logoColor=white)](https://www.phoenixframework.org)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-pgvector-336791?logo=postgresql&logoColor=white)](https://www.postgresql.org)

</div>

## What is Dran

**The knowledge base and the memory your personal AI assistants share**: one
instance holding both the knowledge (a typed wiki graph) and the memory
(trust-scored facts) that your agents read and write over the REST API or the
Hermes plugin, and you browse as a wiki in the browser. You run it yourself,
next to them.

## What's inside

- **Knowledge** — a typed graph of pages joined by typed relations. Four
  built-in page types (`note`, `entity`, `concept`, `reference`) plus custom
  types the instance declares; 13 relation types. TipTap markdown editor
  (tables, code blocks, mermaid, `![[slug]]` embeds of your own pages,
  YouTube/Vimeo/map embeds) with version history and diff view. Hybrid search:
  full-text, fuzzy and semantic, fused.
- **Memory** — atomic facts with trust scores, deduplicated per owner: a
  re-stored fact returns the existing row; a near-duplicate (cosine 0.88–0.95)
  returns `409`, never a silent merge. Feedback is asymmetric (+0.05 helpful /
  −0.10 unhelpful) and untouched facts decay. Facts auto-link to their closest
  pages at ingest.
- **Work** — goals (the WHAT, progress derived from their tasks), tasks (the
  board), plans (the HOW, an ordered checklist). The same rows whether your
  agent creates them by tool or you move them in the UI. `dran_capture` drops
  a quick task into your inbox goal.
- **Services (your own apps)** — connect your Gmail, calendar, GitHub, Slack…
  at `/services`; your agent runs them through 5 fixed tools. The tool catalog
  travels as data, and a service outside the owner's allowlist cannot even be
  listed.
- **Automation** — 3 background workers (`curator`, `link_gardener`,
  `graph_rag`) and 7 scheduled jobs, toggleable and runnable on demand.
- **Visibility** — every page, memory, collection, report, goal and plan is
  `private` (default), `public`, or `shared` with users and groups. A token
  reads exactly what its owner reads.

In the browser: wiki at `/`, goals `/goals`, board `/tasks`, plans `/plans`,
memory `/memory`, 3D graph `/graph`, clusters `/clusters`, collections
`/collections`, reports, `/search`, `/activity`, `/journey`, your connected
apps `/services`, the skills the instance serves `/skills`; your account at
`/settings/account`, the instance at `/admin`.

## Run it

Requirements: Elixir 1.20+ / OTP 29, PostgreSQL 14+ with pgvector.

```bash
git clone git@github.com:alvarolizama/dran.git && cd dran
cp .env.example .env && $EDITOR .env     # SECRET_KEY_BASE, DATABASE_URL, BOTH salts
mix setup
mix phx.server                           # http://localhost:4000
```

First run redirects to `/setup` — whoever arrives first claims the instance as
owner. Your API token lives in **Settings → Account**. Against a local
Postgres without TLS, pass `ECTO_SSL=false`.

`mix precommit` closes the loop: compile `--warnings-as-errors` →
`deps.unlock --unused` → format → `deps.audit` → sobelow → test.

## The Hermes plugin

Gives an agent the tools (`dran_*`, 46) **and** the memory provider
(`dran_memory_*`, 4) — 50 in total, one token, one attribution, its owner's
reach.

1. **Token** — copy your API token (Settings → Account) into the profile's
   `.env` as `DRAN_API_KEY`.
2. **Install** — symlink and enable:

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

3. **Configure** — two surfaces that do not overlap: the plugin's card
   (**Capabilities → Plugins → Dran → gear**: instance, write destination,
   memory switch, 7 tool toggles, the two services budgets) and the memory panel
   (**Settings → Memory & Context**: only the recall knobs, writing
   `$HERMES_HOME/dran/config.json`). Per key, the JSON wins over the card.
   Restart the session and verify: ask it to *"list my pages"* (tools) and
   *"what do you remember about…"* (memory). The service timeouts are a ladder
   across both sides — the client's cap must stay above the instance's
   `DRAN_COMPOSIO_*` budgets; see
   [Presupuestos de servicios](hermes_plugin/dran/README.md#presupuestos-de-servicios-el-ladder).

Full detail: [hermes_plugin/dran/README.md](hermes_plugin/dran/README.md).

## The skills

One suite, versioned with this repo — and **served by Dran itself**: every API
credential (account, group or admin token) gets the 9 built-in skills by
default through `GET /api/skills`, with no install — the catalog is
`lib/dran/skills.ex`, the routes are in `lib/dran_web/router.ex`.

No local install is needed to see them: the plugin already puts the catalog in
front of the agent — a line per skill in the prompt block, the live list and
`q=` search through `dran_skills`, and the body through `dran_skill`. The old
symlinks under `skills.external_dirs` were a second copy of the same bytes,
so they are retired (see
[skills/README.md § Retiring the local install](skills/README.md#retiring-the-local-install)).

One row IS registered locally, and it is a pointer rather than a copy:
`dran:dran-skills-index` (`ctx.register_skill`) is what makes "list the skills"
— which runs the LOCAL listing — land on the live catalog, since the plugin's
tools are deferred behind `tool_search`. No body of the suite is on disk:
[skills/README.md § The one local row](skills/README.md#the-one-local-row-the-pointer).

The files are the SINGLE source of truth: what Dran serves is what those
`SKILL.md` files say, embedded at compile time and reconciled on every boot.

Details: [skills/README.md](skills/README.md).

Point the agent at them with one line in its `soul.md` (identity section —
injected every turn, so it stays a single line):

```text
- **Dran skills (remote)** — to initialize and search them, list the catalog with
  `dran_skills` before a task that may match a skill (pass `q=` to query slug,
  name and description) and load the one that applies with `dran_skill`; nothing
  is copied to disk, and when the user asks to LIST the skills, that catalog IS
  the list. The tools are DEFERRED: reach them through `tool_search` with an
  English query.
```

One credential, no per-agent keys: the account's API token (Settings → Account),
stored in the profile's `.env` as `DRAN_API_KEY` — the tools and the memory
provider share it, and writes carry `X-Hermes-Agent` (the profile name).

## Configuration

Every variable, comment and safe default is in [`.env.example`](.env.example).
Required in production: `DATABASE_URL`, `SECRET_KEY_BASE`, `PHX_HOST`,
`SESSION_SIGNING_SALT`, `SESSION_ENCRYPTION_SALT` (the two salts must differ).

The ones that are Dran's:

| Variable | What it does |
|---|---|
| `DRAN_INFERENCE_API_URL` / `_API_KEY` | any OpenAI-compatible endpoint — e.g. a **TokenGate** instance (`…/v1`): its `/models`, chat and `/embeddings` calls are all Dran uses. Powers embeddings, summaries, semantic search and the workers; without it Dran still works, minus those features |
| `DRAN_COMPOSIO_API_KEY` | scoped project key for the services surface — unset, the whole surface is off |
| `DRAN_COMPOSIO_TIMEOUT` | ms budget for one **read** to Composio, default `12000`. It must stay **below** the Hermes plugin's `services_timeout_s` (15 s): the server has to answer first, so a slow provider arrives as Dran's typed error instead of a dumb socket timeout on the client, where there is no context left |
| `DRAN_COMPOSIO_EXECUTE_TIMEOUT` | ms budget for one tool **execution**, default `25000`. Also below the plugin's `services_run_timeout_s` (45 s). Separate from the read budget because the consequence differs: an execution that ran out of budget may still have landed upstream |
| `UPLOADS_DIR` / `UPLOADS_MAX_SIZE` | where uploads live (mount a volume there in production) and the size cap |
| `GOOGLE_OAUTH_CLIENT_ID` / `_SECRET` | optional Sign in with Google — unset, login is email + password |
| `WORKER_MAX_STEPS` / `WORKER_PER_STEP_TIMEOUT` | worker step budget |
| `SKIP_MIGRATIONS` / `DRAN_RESET` | entrypoint switches (see Production) |

Credentials are not env vars: account tokens in `/settings/account`, group
tokens in `/admin/groups`, the legacy admin token in instance settings.

## Production

```bash
docker build -t dran .
docker run --rm -p 4000:4000 --env-file .env dran
```

- The container migrates before serving; a failed migration aborts the boot.
- The healthcheck is `GET /health` (touches no database) — point the proxy
  there, never at `/` (which redirects to `/login`).
- No account is seeded: the first visitor claims the instance at `/setup` —
  claim it right after the first deploy.
- `force_ssl` is compile-time: behind a VPN without TLS, build with
  `--build-arg DISABLE_FORCE_SSL=1` and run with `PHX_SCHEME=http`.
- Mount a persistent volume at `UPLOADS_DIR`.
- `DRAN_RESET=1` is destructive (drops the whole schema) and runs on every
  container start while set — unset it after the first boot.

## Documentation

- [hermes_plugin/dran/README.md](hermes_plugin/dran/README.md) — the plugin:
  tools, config, and the surfaces it switches
- [skills/README.md](skills/README.md) — the suite Dran serves to agents
- [DESIGN.md](DESIGN.md) — the UI standard

## License

Released under the [MIT License](LICENSE) — Copyright (c) 2026 Álvaro Lizama.
Covers the whole repository: the Elixir/Phoenix server, the Hermes plugin and
the agent skills.
