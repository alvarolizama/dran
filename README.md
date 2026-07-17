# Dran

A personal second-brain application built with Phoenix LiveView. It stores your knowledge as typed pages (notes, concepts, entities, references, goals, plans, todos, artifacts, comparisons) and links them with relations, forming a queryable knowledge graph.

Includes a full markdown editor (TipTap WYSIWYG), an MCP endpoint for AI agent integration, and a REST API.

> **[SKILL.md](SKILL.md)** — Agent operating manual for the Dran MCP server. 18 tools, agent rules, 10 page types with subtypes, troubleshooting, meta validation, recipes, and pitfalls. If you're building an AI agent that connects to Dran via MCP, start there.

## Features

- **10 page types** with type-specific metadata (kinds, statuses, priorities, etc.): note, concept, entity, reference, artifact, goal, plan, todo, comparison, and query
- **Markdown editor** — TipTap WYSIWYG with bidirectional markdown, tables, code blocks, and artifact embeds `![[slug]]`
- **Knowledge graph** — visual graph with pan/zoom, built from explicit and semantic relations
- **Inline editing** — edit any page in-place with autosave
- **File uploads** — upload images, videos, PDFs via the editor toolbar or URL ingest
- **Dashboard** — metrics, recent pages, quick access, todo board summary
- **Kanban board** — drag & drop todos with 6 statuses
- **Goal kanban** — per-goal todo board with drag & drop
- **MCP server** — 18 tools for AI agents to search, read, create, update, delete, relate, lint, ingest, and manage the knowledge graph
- **REST API** — full CRUD for pages, contexts, relations, search, ingest, and maintenance
- **Relations** — see inbound and outbound relations for any page
- **URL ingest** — save web pages (URL only) or download files (PDFs, docs) as references
- **Quality lint** — find orphan pages, stale pages, and contested knowledge
- **Slug rename** — rename a page slug
- **Hybrid search** — unified `search` tool picks full-text, fuzzy, semantic, or hybrid
- **Automatic relations** — `PageAugmenter` creates `semantic` links via embeddings after every capture
- **Autonomous agents** — research and ingest agents that run asynchronously, log every step, and create pages automatically

## Quick start (local dev)

### Prerequisites

- **Elixir 1.15+ and OTP 26+** — managed via [mise](https://mise.jdx.dev) (see `mise.toml`)
- **PostgreSQL 14+** (with `pg_trgm`, `uuid-ossp`, and `pgvector` extensions)
- **Node.js 18+** (for asset building)

### First-time setup

```bash
# 1. Clone and enter the project
git clone git@github.com:alvarolizama/dran.git
cd dran

# 2. Copy the env template and edit values
cp .env.example .env
$EDITOR .env    # set SECRET_KEY_BASE, DRAN_PASSWORD, etc.

# 3. Install deps, create the DB, run migrations, build assets, and seed
mix setup
```

> **mise auto-loads `.env`:** If you use `mise`, the `.env` file is loaded automatically via `mise.toml` (`_.file = ".env"`). No need to `source .env` manually. If you don't use mise, use `direnv allow` or export the vars in your shell.

`mix setup` runs (in order):

1. `mix deps.get` — install Elixir dependencies
2. `mix ecto.create` — create the database
3. `mix ecto.migrate` — run migrations
4. `mix assets.setup` — install Tailwind & esbuild
5. `mix assets.build` — build CSS & JS bundles
6. `mix seed` — create the default context (uses `DRAN_CONTEXT_SLUG` / `DRAN_CONTEXT_NAME`)

### Running the dev server

```bash
mix phx.server
```

Visit [localhost:4000](http://localhost:4000). You'll be redirected to login.

### Default dev credentials

| Setting      | Default       | Env var             |
| ------------ | ------------- | ------------------- |
| Username     | `admin`       | `DRAN_USERNAME`     |
| Password     | `dran`        | `DRAN_PASSWORD`     |
| API token    | `dran-token`  | `DRAN_API_TOKEN`    |
| Context slug | `personal`    | `DRAN_CONTEXT_SLUG` |
| Context name | `Personal`    | `DRAN_CONTEXT_NAME` |

> **Never use these defaults in production.** Set `DRAN_PASSWORD` and `DRAN_API_TOKEN` to strong random values before deploying.

### Environment variables

See [`.env.example`](.env.example) for the full list with comments. The most important ones for local dev:

```bash
SECRET_KEY_BASE=$(mix phx.gen.secret)
DATABASE_URL=ecto://brain:brain_dev_2026@localhost/dran_dev
DRAN_PASSWORD=$(openssl rand -hex 32)
DRAN_API_TOKEN=$(openssl rand -hex 32)
```

#### Core

| Variable          | Required | Notes                                                          |
| ----------------- | -------- | -------------------------------------------------------------- |
| `SECRET_KEY_BASE` | yes      | Output of `mix phx.gen.secret`                                 |
| `DATABASE_URL`    | yes      | Postgres connection string                                     |
| `DRAN_PASSWORD`   | yes      | Admin login password                                           |
| `DRAN_API_TOKEN`  | yes      | Bearer token for API / MCP                                     |
| `PHX_HOST`        | yes      | Public hostname (e.g. `localhost`, `dran.example.com`)         |
| `PHX_PORT`        | no       | External port for generated URLs (default: `443`)              |
| `PHX_SCHEME`      | no       | `https` or `http` (default: `https`)                           |
| `PORT`            | no       | HTTP listener port (default: `4000`)                           |
| `POOL_SIZE`       | no       | DB connection pool size (default: `10`)                        |
| `ECTO_IPV6`       | no       | `true` or `1` to force IPv6 DB socket                          |

#### Inference API (optional)

| Variable                        | Required | Notes                                                    |
| ------------------------------- | -------- | -------------------------------------------------------- |
| `DRAN_INFERENCE_API_URL`        | no       | Base URL of OpenAI-compatible inference server (`…/v1`)  |
| `DRAN_INFERENCE_API_KEY`        | no*      | API key (required if URL is set)                         |
| `DRAN_INFERENCE_CHAT_MODEL`     | no       | Chat/text model (default: `Ornith-1.0-9B`)               |
| `DRAN_INFERENCE_EMBEDDING_MODEL`| no       | Embeddings model (default: `Qwen3-Embedding`)            |
| `DRAN_INFERENCE_RERANK_MODEL`   | no       | Rerank model (default: `Qwen3-Reranker`)                 |
| `DRAN_INFERENCE_MARKITDOWN_MODEL`| no      | Document-to-markdown model (default: `MarkItDown`)       |
| `DRAN_INFERENCE_ASR_MODEL`      | no       | Audio transcription model (default: `Qwen3-ASR`)         |
| `DRAN_INFERENCE_VISION_MODEL`   | no       | Vision/chat model for images (default: `Ornith-1.0-9B`)  |

> `DRAN_INFERENCE_API_KEY` is required whenever `DRAN_INFERENCE_API_URL` is set.

#### Agents (optional)

| Variable                  | Required | Notes                                      |
| ------------------------- | -------- | ------------------------------------------ |
| `AGENT_MAX_STEPS`         | no       | Max steps per agent run (default: `150`)   |
| `AGENT_PER_STEP_TIMEOUT`  | no       | Per-step timeout in ms (default: `120000`)|

#### Firecrawl (optional)

| Variable           | Required | Notes                              |
| ------------------ | -------- | ---------------------------------- |
| `FIRECRAWL_API_KEY`| no       | API key for web search + scrape    |

#### Production-only

| Variable            | Required | Notes                                                        |
| ------------------- | -------- | ------------------------------------------------------------ |
| `DISABLE_FORCE_SSL` | no       | Set to `1` at **build time** to disable `force_ssl` redirect |
| `DNS_CLUSTER_QUERY` | no       | libcluster query for multi-node setups                       |
| `UPLOADS_DIR`       | no       | Upload storage path (default: `priv/static/uploads`)         |
| `UPLOADS_MAX_SIZE`  | no       | Max upload bytes (default: `104857600` = 100 MiB)            |

### Pre-commit checks

Before committing, always run:

```bash
mix precommit
```

This runs `compile --warnings-as-errors`, `deps.unlock --unused`, `format`, and `test`. Fix any issues it reports before pushing.

## Inference API

Dran can talk to an OpenAI-compatible inference server to add embeddings, reranking, and document-to-markdown conversion to the second brain.

Supported capabilities:

- **Embeddings** — `POST /v1/embeddings`
- **Reranking** — `POST /v1/rerank`
- **Document-to-markdown** — `POST /v1/chat/completions` with a file content part
- **Chat / text generation** — `POST /v1/chat/completions`
- **Audio transcription** — `POST /v1/audio/transcriptions`
- **Image descriptions** — `POST /v1/chat/completions` with image content part

The server is configured via environment variables:

```bash
DRAN_INFERENCE_API_URL=http://<inference-host>:8000/v1
DRAN_INFERENCE_API_KEY=<your-key>
```

> Don't put real hostnames, VPN domains, or tokens in public repo files. Use `.env` for the real values.

### Available models

The current local/VPN server exposes these models (verify at runtime with `GET /v1/models`):

| Model | Capability | Endpoint |
| ----- | ---------- | -------- |
| `Qwen3-Embedding` | text embeddings | `POST /v1/embeddings` |
| `Qwen3-Reranker` | rerank search results | `POST /v1/rerank` |
| `MarkItDown` | PDF/DOCX/PPTX/TXT → markdown | `POST /v1/chat/completions` |
| `Qwen3.5-9B` | chat / text generation / vision | `POST /v1/chat/completions` |
| `Qwen3-ASR` | audio transcription | `POST /v1/audio/transcriptions` |

### How Dran can use it

1. **Unified search** — `Brain.search/2` picks full-text, fuzzy, semantic or hybrid automatically based on the query and inference availability.
2. **Semantic search** — generate embeddings for page title/body, store them in the `pgvector` column, and add vector search over the knowledge graph.
3. **Better search ranking** — use the reranker to reorder FTS/vector candidates before returning them.
4. **Rich file ingest** — convert uploaded PDFs, Word docs and PowerPoints to Markdown with `MarkItDown`, then index them as pages.
5. **Automatic relations** — after a page is created/updated, `Dran.Brain.PageAugmenter` asynchronously finds semantically similar pages and creates `related` relations when confidence is high.

For endpoint request/response examples and integration patterns, see [`references/inference-api.md`](references/inference-api.md). For the implementation roadmap, see [`references/inference-implementation-plan.md`](references/inference-implementation-plan.md).

### Migrations

Migrations create the schema automatically. They are pure DDL — no data is inserted.

```bash
mix ecto.create    # create the database
mix ecto.migrate   # run migrations (no seeds)
```

The migrations create:

- `contexts` — workspaces (personal, work, etc.)
- `pages` — knowledge pages with JSONB `meta` field
- `relations` — directed links between pages
- `page_versions` — body snapshots for version history
- `brain_log` — audit log of all actions

### Seeds

Seeds create **only the default context** (no test data). The seed script is idempotent — it checks if the context already exists before inserting.

```bash
# Dev
mix seed

# Production (release)
bin/dran eval Dran.Release.seed
```

This is a separate step from migrations. `mix setup` includes `mix seed` at the end for convenience. In production, `bin/setup` runs create DB → migrate → seed (all idempotent).

### Reset (destructive)

```bash
mix ecto.reset  # drop + create + migrate + seed
```

## Page types

Every piece of knowledge is a page with a `page_type`. Some types have a `kind` sub-type (in `meta.kind`):

| Type         | Purpose                       | Subtypes (meta.kind)                                  | Key meta fields                                    |
| ------------ | ----------------------------- | ----------------------------------------------------- | -------------------------------------------------- |
| `note`       | Thoughts, journal, ideas      | thought, journal, idea, meeting, question, quote      | kind, date, author, attendees                      |
| `concept`    | Abstract ideas, techniques    | technique, pattern, discipline, theory                | kind, domain, parent_concept                       |
| `entity`     | People, companies, tools      | person, company, product, tool, place, event          | kind, location, external_url, aliases              |
| `reference`  | External sources              | article, paper, video, podcast, book                  | kind, source_url, published_at                     |
| `artifact`   | Files and deliverables        | document, code, design, deliverable, file             | kind, filename, mime_type, storage_path, sha256     |
| `goal`       | Objectives with target dates  | —                                                     | health (green/yellow/red), target_date, start_date, team |
| `plan`       | Time-horizoned plans          | —                                                     | horizon (weekly/monthly/quarterly/yearly), status (draft/active/on_hold/completed/archived), period |
| `todo`       | Actionable items              | —                                                     | kanban_status (backlog/this_week/today/in_progress/done/cancelled), priority (low/medium/high/urgent), goal_slug, due_date |
| `comparison` | Side-by-side analyses         | —                                                     | entities, criteria, verdict                        |

### Embeds

- `![[slug]]` — embed an artifact (renders as image/video/audio/PDF)
- `![[slug|Alt Text]]` — embed with alt text

Embeds auto-create `embeds` relations. Plain `[[slug]]` wikilinks are no longer supported — link pages explicitly with `create_relation` or let the `PageAugmenter` create `semantic` relations automatically.

### Relations

Relations are **directed** (source → target) and typed:

- `related` — generic connection (create manually via `create_relation`)
- `part_of` — hierarchy (A is part of B)
- `supersedes` — replacement (A replaces/obsoletes B)
- `contradicts` — conflict (A contradicts B)
- `embeds` — source embeds target (auto-created from `![[slug]]`)
- `semantic` — auto-created by `PageAugmenter` when pages are semantically similar

For explicit typed relations (`contradicts`, `supersedes`, `part_of`), use the MCP `create_relation`
tool or the `POST /api/relations` REST endpoint.

## Production deployment

Dran ships as a standard Elixir release with three helper scripts in `rel/overlays/bin/`:

| Script         | What it does                                                                                  |
| -------------- | --------------------------------------------------------------------------------------------- |
| `bin/server`   | Starts the Phoenix server (`PHX_SERVER=true bin/dran start`). Use this as the **start command**. |
| `bin/migrate`  | Runs `Dran.Release.migrate/0` (pending migrations only). Use this for incremental deploys.    |
| `bin/setup`    | Idempotent: creates the DB (if missing), then migrates, then seeds. Use this for the **first deploy** or as a pre-deploy hook. |

All three are wrapped in `rel/overlays/bin/` and ship inside the release at `_build/prod/rel/dran/bin/`.

### Step 1 — Build the release

```bash
# Install Hex/Rebar (first time only)
mix local.hex --force
mix local.rebar --force

# Fetch prod-only deps
MIX_ENV=prod mix deps.get --only prod

# Compile and build production assets
MIX_ENV=prod mix compile
MIX_ENV=prod mix assets.deploy

# Assemble the release
MIX_ENV=prod mix release
```

The release ends up in `_build/prod/rel/dran/`. The whole directory is self-contained — copy it to the target machine, or build a container image from it.

### Step 2 — Provision the database

The release expects a Postgres database to exist. Create it once, manually, **before the first deploy**:

```bash
# From any host that can reach the DB:
PGPASSWORD=ADMIN_PASSWORD createdb -h DB_HOST -U ADMIN_USER dran_prod
```

The app's DB user only needs `CONNECT`, `USAGE`, and DML/DDL on `dran_prod`. If you prefer, you can skip this step entirely and let `bin/setup` create the database on the first run — but the user in `DATABASE_URL` needs `CREATEDB` privilege for that.

### Step 3 — Configure environment variables

The release reads all configuration from environment variables at startup. There is no `.env` file inside the release. Set these in your platform's secret manager (Coolify env vars, Fly secrets, BWS, etc.):

| Variable            | Required | Notes                                                                                |
| ------------------- | -------- | ------------------------------------------------------------------------------------ |
| `SECRET_KEY_BASE`   | yes      | Output of `mix phx.gen.secret`                                                       |
| `DATABASE_URL`      | yes      | `postgres://user:***@host:5432/dran_prod`                                           |
| `DRAN_PASSWORD`     | yes      | Strong password for the admin user                                                   |
| `DRAN_API_TOKEN`    | yes      | Long random token for MCP / REST clients (`openssl rand -hex 32`)                    |
| `PHX_HOST`          | yes      | Public domain (e.g. `dran.example.com`)                                              |
| `PHX_PORT`          | no       | External port for generated URLs (default: `443`)                                    |
| `PHX_SCHEME`        | no       | `https` or `http` (default: `https`)                                                 |
| `PORT`              | no       | Defaults to `4000`. Most platforms inject it.                                        |
| `POOL_SIZE`         | no       | Defaults to `10`. Bump under load.                                                   |
| `UPLOADS_DIR`       | no       | Defaults to `priv/static/uploads`. Mount a persistent volume here.                   |
| `UPLOADS_MAX_SIZE`  | no       | Defaults to `104857600` (100 MiB).                                                   |
| `ECTO_IPV6`         | no       | `true` or `1` to force IPv6 DB socket.                                               |
| `DNS_CLUSTER_QUERY` | no       | libcluster query, only for multi-node setups.                                        |
| `DISABLE_FORCE_SSL` | no       | Set to `1` at **build time** to disable `force_ssl` redirect (plain HTTP deployments). |
| `AGENT_MAX_STEPS`   | no       | Max steps per agent run (default: `150`)                                             |
| `AGENT_PER_STEP_TIMEOUT` | no  | Per-step timeout in ms (default: `120000`)                                           |
| `FIRECRAWL_API_KEY` | no       | API key for Firecrawl web search + scrape                                            |

> **Never bake secrets into a Dockerfile.** Pass them as runtime env vars only. Coolify, Fly, and Kubernetes all support this natively.

### Step 4 — Start the release

#### Option A — Bare metal / VM

```bash
# 1. Copy release to the server
rsync -avz _build/prod/rel/dran/ user@server:/opt/dran/

# 2. First deploy: create DB, run migrations, seed
ssh user@server 'cd /opt/dran && bin/setup'

# 3. Start the server (foreground, for systemd)
ssh user@server 'cd /opt/dran && bin/server'

# Or run as a daemon
ssh user@server 'cd /opt/dran && bin/dran daemon'
```

For a systemd unit, point `ExecStart` at `/opt/dran/bin/server`.

#### Option B — Container (Coolify / Railpack / Nixpacks)

The simplest path is letting the build pack auto-detect the Elixir app and produce a container. Set these in the resource config:

- **Build pack:** Nixpacks or Railpack (auto-detects `mix.exs`)
- **Start command:** `bin/server`
- **Pre-deploy command:** `bin/setup` (creates DB → migrates → seeds, all idempotent)
- **Port:** `4000` (or whatever your reverse proxy expects)

> `bin/setup` is safe to run on every deploy. On a fresh database it creates the schema and seeds the default context. On subsequent deploys it short-circuits (the DB already exists) and only runs pending migrations + the idempotent seed.

#### Option C — Custom `docker run`

If you build a custom image (e.g. with `mix phx.gen.release --docker`), the final `CMD` should be `["bin/server"]` and you should run `bin/setup` as a one-off init container or via an entrypoint wrapper.

### Step 5 — Verify

```bash
# Health check (replace with your real domain)
curl -fsSL https://dran.example.com/health

# MCP endpoint (requires bearer token)
curl -fsSL https://dran.example.com/api/mcp \
  -H "Authorization: Bearer your-token-here"
```

## AI Agent Integration

### MCP (Model Context Protocol)

Dran exposes an MCP endpoint at `POST /api/mcp` using the Streamable HTTP transport.

**Client configuration (e.g. Claude Desktop):**

```json
{
  "mcpServers": {
    "dran": {
      "url": "http://localhost:4000/api/mcp",
      "headers": {
        "Authorization": "Bearer dran-token"
      }
    }
  }
}
```

**Available tools:**

| Tool               | Description                                                            |
| ------------------ | ---------------------------------------------------------------------- |
| `search`           | Unified search: auto picks full-text, fuzzy, semantic or hybrid         |
| `semantic_search`  | Deprecated alias for `search` with `strategy=semantic`                   |
| `get_page`         | Get a page by slug (returns full markdown content)                     |
| `create_page`      | Create a new page with type-specific meta                              |
| `update_page`      | Update an existing page (title, body, tags, meta)                      |
| `delete_page`      | Delete a page by slug (cascades to relations + versions)               |
| `create_todo`      | Create a todo with kanban status, priority, due date                   |
| `update_todo`      | Update a todo's status/priority/due date (merges meta, no full replace)|
| `create_relation`  | Create a typed relation between two pages                              |
| `delete_relation`  | Delete a relation between two pages (by slug pair + optional type)      |
| `get_links`        | Get inbound + outbound relations for a page                            |
| `list_pages`       | List pages with filters (type, tag, status, limit)                     |
| `stats`            | Aggregate statistics for a context (page counts, todos by status, orphans, total relations) |
| `lint`             | Quality report: orphans, stale pages, and contested knowledge          |
| `rename_slug`      | Rename a page's slug                                                   |
| `ingest_url`       | Save a URL (HTML to save link; files to download and store)           |
| `start_agent`      | Start an autonomous agent (`research` or `ingest`)                       |
| `get_agent_session`| Poll an agent session for status, summary, and steps                  |

**Resources:**

| URI                       | Description                                       |
| ------------------------- | ------------------------------------------------- |
| `page://{context}/{slug}` | Full page content as markdown                     |
| `goal://{context}/{slug}` | Goal detail with related todos and plans (JSON)   |
| `wiki://{context}/index`  | All pages in a context (slug + title + type)      |

**Prompts:**

| Prompt           | Description                                                          |
| ---------------- | -------------------------------------------------------------------- |
| `research_topic` | Scaffold a research page with outline, sources, and questions        |
| `brainstorm`     | Generate ideas around a topic (creates notes with kind: idea)        |
| `goal_review`    | Review a goal's status, todos, and plans                             |

### Agent workflow

1. **Search** — use `search` to find existing pages before creating new ones
2. **Read** — use `get_page` to read full content, or `list_pages` for a filtered overview
3. **Create** — use `create_page` with the appropriate `page_type` and `meta`. Use `create_todo` for action items
4. **Update** — use `update_page` to refine content. Use `update_todo` to change a todo's status/priority (merges meta)
5. **Delete** — use `delete_page` to remove a page (cascades to relations + versions)
6. **Relate** — use `create_relation` for typed relationships (`contradicts`, `supersedes`, `part_of`, `embeds`). Use `delete_relation` to remove. Embeds (`![[slug]]`) auto-create `embeds` relations
7. **Inspect** — use `get_links` to see inbound + outbound relations for a page
8. **Stats** — use `stats` for a context overview (page counts, todos by status, orphans, total relations)
9. **Rename** — use `rename_slug` to rename a page slug
10. **Ingest** — use `ingest_url` to save web pages or download files as references
11. **Lint** — use `lint` to find orphans, stale pages, and contested knowledge

### Autonomous agents

Dran can delegate longer tasks to autonomous ReAct agents:

- **`start_agent` / `get_agent_session`** — start a research or ingest session and poll for progress.
- **Research agent** — searches the web, scrapes sources, checks existing pages, and creates 1-5 new pages.
- **Ingest agent** — validates, inspects, downloads, and creates reference pages from URLs.

> A search-only agent is on the roadmap; today `search` / `semantic_search` tools return results directly without creating pages.

Agents run asynchronously under `Dran.Relations.TaskSupervisor`, persist every step to `agent_sessions` / `agent_steps`, and broadcast live updates to the UI and to PubSub topics (`agents:<session_id>` and `agents:all`).

Agents are also exposed as LiveView pages at `/agents/:type` and individual sessions at `/agents/:type/:id`. From the CLI, run an agent with `mix dran.agent --type research --context personal --input "topic"`.

### Example: create a note

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/call",
  "params": {
    "name": "create_page",
    "arguments": {
      "context": "personal",
      "title": "Learning Elixir",
      "slug": "learning-elixir",
      "page_type": "note",
      "body": "Today I learned about Elixir pattern matching and the `=` match operator.",
      "meta": {"kind": "journal", "date": "2026-06-21"},
      "tags": ["programming", "elixir"]
    }
  }
}
```

## REST API

All API endpoints require a bearer token: `Authorization: Bearer <DRAN_...N>`.

| Method   | Path                                       | Description                                                  |
| -------- | ------------------------------------------ | ------------------------------------------------------------ |
| `GET`    | `/api/pages?context=personal`              | List pages (no body by default, `?include=body` for full)   |
| `POST`   | `/api/pages`                               | Create a page                                                |
| `GET`    | `/api/pages/:slug?context=personal`        | Get a page (no body by default, `?include=body` for full)    |
| `PUT`    | `/api/pages/:slug?context=personal`        | Update a page                                                |
| `DELETE` | `/api/pages/:slug?context=personal`        | Delete a page                                                |
| `GET`    | `/api/pages/:slug/links?context=personal`  | Get page relations (outbound + inbound)                      |
| `GET`    | `/api/pages/:slug/graph?context=personal`  | Get page subgraph                                            |
| `POST`   | `/api/relations`                           | Create a relation (`{source_slug, target_slug, relation_type, context}`) |
| `DELETE` | `/api/relations/:id`                       | Delete a relation                                            |
| `GET`    | `/api/search?q=...&context=personal`       | Unified search (auto, or `?strategy=fts\|fuzzy\|semantic\|hybrid`) |
| `GET`    | `/api/search/fuzzy?q=...&context=personal` | Fuzzy search alias (`?strategy=fuzzy`)                            |
| `GET`    | `/api/search/semantic?q=...&context=personal` | Semantic/hybrid alias (`?strategy=semantic\|hybrid`)           |
| `GET`    | `/api/goals?context=personal`              | List goals                                                   |
| `GET`    | `/api/goals/:slug?context=personal`        | Goal detail with related todos and plans                     |
| `GET`    | `/api/todos?context=personal&status=...`   | List todos (filterable by kanban status)                     |
| `POST`   | `/api/todos`                               | Create a todo                                                |
| `PUT`    | `/api/todos/:id`                           | Update a todo (e.g. change status, merges meta)              |
| `POST`   | `/api/ingest`                              | Ingest a URL (`{url, context, slug?, tags?}`)                 |
| `GET`    | `/api/index?context=personal`              | Wiki index (all slugs + titles)                              |
| `GET`    | `/api/graph?context=personal`              | Full knowledge graph                                         |
| `GET`    | `/api/lint?context=personal`               | Quality lint report                                          |
| `GET`    | `/api/log?context=personal`                | Audit log                                                    |
| `GET`    | `/api/contexts`                            | List contexts                                                |
| `POST`   | `/api/contexts`                            | Create a context                                             |
| `GET`    | `/api/contexts/:slug`                      | Get a context                                                |
| `PUT`    | `/api/contexts/:slug`                      | Update a context                                             |
| `DELETE` | `/api/contexts/:slug`                      | Delete a context                                             |
| `POST`   | `/api/mcp`                                 | MCP JSON-RPC endpoint                                        |

### Agents CLI

Run agents from the terminal:

```bash
mix dran.agent --type research --context personal --input "Yeshe Walmo"
mix dran.agent --type ingest  --context personal --input "https://example.com/article"
```

## Tech stack
- **Phoenix 1.8** with LiveView
- **TipTap v3** markdown editor with `@tiptap/markdown` for bidirectional markdown
- **MDEx** (comrak) for server-side markdown rendering with GFM + sanitization
- **MCP** (Model Context Protocol) for AI agent integration
- **Tailwind CSS v4** + daisyUI for styling

## License

MIT
