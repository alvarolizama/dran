# Dran

A personal second-brain application built with Phoenix LiveView. It stores your knowledge as typed pages (notes, concepts, entities, references, goals, plans, todos, artifacts, comparisons) and links them with relations, forming a queryable knowledge graph.

Includes a full markdown editor (TipTap WYSIWYG), an MCP endpoint for AI agent integration, and a REST API.

## Features

- **9 page types** with type-specific metadata (kinds, statuses, priorities, etc.)
- **Markdown editor** — TipTap WYSIWYG with bidirectional markdown, tables, code blocks, wikilinks `[[slug]]`, and embeds `![[slug]]`
- **Knowledge graph** — visual graph with pan/zoom, auto-generated from wikilinks
- **Inline editing** — edit any page in-place with autosave
- **File uploads** — upload images, videos, PDFs via the editor toolbar or URL ingest
- **Dashboard** — metrics, recent pages, quick access, todo board summary
- **Kanban board** — drag & drop todos with 6 statuses
- **Goal kanban** — per-goal todo board with drag & drop
- **MCP server** — AI agents can search, create, update, read, and lint pages
- **REST API** — full CRUD for pages, contexts, relations, search, and ingest
- **Backlinks** — see which pages link to the current page
- **URL ingest** — save web pages (URL only) or download files (PDFs, docs) as references
- **Quality lint** — find orphan pages, broken wikilinks, stale pages

## Quick Start

### Prerequisites

- Elixir 1.15+
- PostgreSQL 14+ (with `pg_trgm` and `uuid-ossp` extensions)
- Node.js 18+ (for asset building)

### Installation

```bash
git clone git@github.com:alvarolizama/dran.git
cd dran
mix setup
```

`mix setup` runs:
1. `mix deps.get` — install Elixir dependencies
2. `mix ecto.setup` — create DB, run migrations, seed default context
3. `mix assets.setup` — install Tailwind & esbuild
4. `mix assets.build` — build CSS & JS bundles

### Running

```bash
mix phx.server
```

Visit [localhost:4000](http://localhost:4000). You'll be redirected to login.

### Default credentials

| Setting | Default | Env var |
|---|---|---|
| Username | `admin` | `DRAN_USERNAME` |
| Password | `dran` | `DRAN_PASSWORD` |
| API token | `dran-token` | `DRAN_API_TOKEN` |
| Context slug | `personal` | `DRAN_CONTEXT_SLUG` |
| Context name | `Personal` | `DRAN_CONTEXT_NAME` |

**Change these in production!** Set the environment variables before running `mix setup` (so the seed creates the right context) and before starting the server.

### Environment variables

```bash
export DRAN_USERNAME="myuser"
export DRAN_PASSWORD="strongpassword"
export DRAN_API_TOKEN="my-secret-token"
export DRAN_CONTEXT_SLUG="work"
export DRAN_CONTEXT_NAME="Work"
export DATABASE_URL="ecto://user:pass@localhost/dran"
export SECRET_KEY_BASE="$(mix phx.gen.secret)"
export PORT=4000
export UPLOADS_DIR="priv/static/uploads"
export UPLOADS_MAX_SIZE=104857600  # 100MB in bytes
```

## Database setup

### Migrations

Migrations create the schema automatically:

```bash
mix ecto.create    # create the database
mix ecto.migrate   # run migrations
```

The migrations create:
- `contexts` — workspaces (personal, work, etc.)
- `pages` — knowledge pages with JSONB `meta` field
- `relations` — directed links between pages
- `page_versions` — body snapshots for version history
- `brain_log` — audit log of all actions

### Seeds

Seeds create the default context from `DRAN_CONTEXT_SLUG` / `DRAN_CONTEXT_NAME`:

```bash
mix run priv/repo/seeds.exs
```

Or automatically via `mix ecto.setup`.

### Reset

```bash
mix ecto.reset  # drop + create + migrate + seed
```

## Page types

Every piece of knowledge is a page with a `page_type`. Some types have a `kind` sub-type (in `meta.kind`):

| Type | Purpose | Subtypes (meta.kind) | Key meta fields |
|---|---|---|---|
| `note` | Thoughts, journal, ideas | thought, journal, idea, meeting, question, quote | kind, date, author |
| `concept` | Abstract ideas, techniques | technique, pattern, discipline, theory | kind, domain, parent_concept |
| `entity` | People, companies, tools | person, company, product, tool, place, event | kind, location, external_url |
| `reference` | External sources | article, paper, video, podcast, book | kind, source_url, published_at |
| `artifact` | Files and deliverables | document, code, design, deliverable, file | kind, filename, mime_type, storage_path |
| `goal` | Objectives with target dates | — | health (green/yellow/red), target_date, start_date |
| `plan` | Time-horizoned plans | — | horizon (weekly/monthly/quarterly/yearly), status (draft/active/on_hold/completed/archived) |
| `todo` | Actionable items | — | kanban_status (backlog/this_week/today/in_progress/done/cancelled), priority (low/medium/high/urgent), goal_slug, due_date |
| `comparison` | Side-by-side analyses | — | entities, criteria, verdict |

### Wikilinks & embeds

- `[[slug]]` — link to another page (auto-creates `related` relation)
- `[[slug\|Display Text]]` — link with custom display text
- `![[slug]]` — embed an artifact (renders as image/video/audio/PDF)
- `![[slug\|Alt Text]]` — embed with alt text

### Relations

- `related` — generic connection (auto-created from wikilinks)
- `part_of` — hierarchy (A is part of B)
- `supersedes` — replacement (A replaces B)
- `contradicts` — conflict (A contradicts B)
- `embeds` — source embeds target (auto-created from `![[slug]]`)

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

| Tool | Description |
|---|---|
| `search` | Full-text search across pages (returns title, slug, type, excerpt) |
| `get_page` | Get a page by slug (returns full markdown content) |
| `create_page` | Create a new page with type-specific meta |
| `update_page` | Update an existing page (title, body, tags, meta) |
| `create_todo` | Create a todo with kanban status, priority, due date |
| `lint` | Quality report: orphans, broken wikilinks, stale pages |
| `ingest_url` | Save a URL (HTML → save link; files → download & store) |

**Resources:**

| URI | Description |
|---|---|
| `page://{context}/{slug}` | Full page content as markdown |
| `goal://{context}/{slug}` | Goal detail with related todos and plans (JSON) |
| `wiki://{context}/index` | All pages in a context (slug + title + type) |

**Prompts:**

| Prompt | Description |
|---|---|
| `research_topic` | Scaffold a research page with outline, sources, and questions |
| `brainstorm` | Generate ideas around a topic (creates notes with kind: idea) |
| `goal_review` | Review a goal's status, todos, and plans |

### Agent workflow

1. **Search** — use `search` to find existing pages before creating new ones
2. **Read** — use `get_page` to read full content, or read `wiki://{context}/index` for an overview
3. **Create** — use `create_page` with the appropriate `page_type` and `meta`. Use `create_todo` for action items.
4. **Update** — use `update_page` to refine content. Version auto-increments on body change.
5. **Ingest** — use `ingest_url` to save web pages or download files as references
6. **Lint** — use `lint` to find orphans, broken links, and stale pages

### Example: create a note with a wikilink

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
      "body": "Today I learned about [[elixir|Elixir]] pattern matching.\n\nSee [[phoenix]] for web framework.",
      "meta": {"kind": "journal", "date": "2026-06-21"},
      "tags": ["programming", "elixir"]
    }
  }
}
```

## REST API

All API endpoints require a bearer token: `Authorization: Bearer dran-token`

| Method | Path | Description |
|---|---|---|
| `GET` | `/api/pages?context=personal` | List pages (no body by default, `?include=body` for full) |
| `POST` | `/api/pages` | Create a page |
| `GET` | `/api/pages/:slug?context=personal` | Get a page (no body by default, `?include=body` for full) |
| `PUT` | `/api/pages/:slug?context=personal` | Update a page |
| `DELETE` | `/api/pages/:slug?context=personal` | Delete a page |
| `GET` | `/api/pages/:slug/links?context=personal` | Get page relations (outbound + inbound) |
| `GET` | `/api/pages/:slug/graph?context=personal` | Get page subgraph |
| `GET` | `/api/search?q=...&context=personal` | Full-text search |
| `GET` | `/api/search/fuzzy?q=...&context=personal` | Fuzzy search (trigram similarity) |
| `POST` | `/api/ingest` | Ingest a URL (`{url, context, slug?, tags?}`) |
| `GET` | `/api/index?context=personal` | Wiki index (all slugs + titles) |
| `GET` | `/api/graph?context=personal` | Full knowledge graph |
| `GET` | `/api/lint?context=personal` | Quality lint report |
| `GET` | `/api/log?context=personal` | Audit log |
| `GET` | `/api/contexts` | List contexts |

## Production deployment

### Using environment variables

```bash
export PHX_SERVER=true
export DATABASE_URL="ecto://user:pass@host/dran"
export SECRET_KEY_BASE="$(mix phx.gen.secret)"
export DRAN_USERNAME="admin"
export DRAN_PASSWORD="strong-password"
export DRAN_API_TOKEN="strong-token"
export DRAN_CONTEXT_SLUG="personal"
export DRAN_CONTEXT_NAME="Personal"
export PORT=4000
```

### Build and run

```bash
mix assets.deploy
mix release
PORT=4000 _build/dev/rel/dran/bin/dran start
```

## Tech stack

- **Phoenix 1.8** with LiveView
- **Ecto + PostgreSQL** with pg_trgm (fuzzy search) and generated tsvector (FTS)
- **TipTap v3** markdown editor with `@tiptap/markdown` for bidirectional markdown
- **MDEx** (comrak) for server-side markdown rendering with GFM + sanitization
- **MCP** (Model Context Protocol) for AI agent integration
- **Tailwind CSS v4** + daisyUI for styling

## License

MIT