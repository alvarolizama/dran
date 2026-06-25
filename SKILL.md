---
name: dran-second-brain
description: "Use when operating Álvaro's Dran second brain via MCP. 17 tools: search, read, create, update, delete, relate, lint, rename, stats, ingest, start_agent, get_agent_session. 9 page types (notes, concepts, entities, references, goals, plans, todos, artifacts, comparisons) in a personal knowledge graph backed by Phoenix LiveView + PostgreSQL. Triggers on any Dran / segundo cerebro / brain task: capturing thoughts, research, ingesting URLs, managing goals and todos, running the knowledge graph lint, wikilinking pages, renaming slugs, or delegating to agents."
version: 2.0.0
author: Álvaro Lizama
license: MIT
metadata:
  hermes:
    tags: [dran, second-brain, mcp, knowledge-graph, notes, productivity]
    related_skills: [obsidian, notion, apple-notes]
---

# Dran — Second Brain (MCP)

## Overview

Dran is Álvaro's personal second brain, a Phoenix LiveView + PostgreSQL app that stores
all knowledge as **typed pages** linked together by **relations**, forming a queryable
knowledge graph. The agent (yo) drives Dran through its **MCP endpoint** (`POST /api/mcp`,
Streamable HTTP, spec 2025-03-26) using a bearer token.

The agent's job is not to dump data — it is to **capture, enrich, and maintain**
Álvaro's knowledge graph so the second brain stays useful. Quality > volume. Every
new page should be meaningful; Dran then links it automatically to existing
knowledge.

## How Dran captures knowledge now

The agent/MCP **passes page content as plain text** (no wikilinks required). On
every `create_page` / `update_page`, Dran:

1. Extracts or refines `summary` and `tags` via the configured inference model.
2. Generates and stores a vector embedding of `title + summary + body`.
3. Asynchronously finds the closest semantic neighbours in the same context.
4. Creates `semantic` relations to those neighbours automatically.

Wikilinks (`[[slug]]`) still work, but **they are optional**. The graph grows
mainly through embeddings + automatic `semantic` relations.

## When to Use

- Loading this skill is the right call whenever Álvaro references Dran, the segundo
  cerebro, the brain, his knowledge graph, a goal/plan/todo, a note/concept/entity
  he wants stored, a research topic to scaffold, or a URL/article to ingest.
- Use for: capturing thoughts, journaling, taking research notes, ingesting URLs,
  managing todos + goals + plans, querying the knowledge graph, linting for orphans
  and broken links, building comparisons between tools/concepts, or delegating longer
  discovery tasks to agents.
- Do **not** use for: ephemeral chat (use memory tool), session-only state, large
  binary file storage (use `artifact` page type with a `storage_path` only when the
  file is genuinely worth keeping), duplicating content that already lives in another
  system Dran syncs with.

## Endpoint & Auth (verified live)

| Item        | Value                                                              |
| ----------- | ------------------------------------------------------------------ |
| Transport   | Streamable HTTP (MCP spec 2025-03-26)                              |
| POST        | `POST http://<dran-host>/api/mcp` — JSON-RPC → JSON             |
| GET         | `GET /api/mcp` → 405 (server-initiated SSE not supported in v1)    |
| DELETE      | `DELETE /api/mcp` — terminate session, returns 200                 |
| Auth header | `Authorization: Bearer ${MCP_DRAN_API_KEY}` (read `~/.hermes/.env`) |
| Accept      | MUST include `application/json` or `text/event-stream` or `*/*`   |
| **Default context** | **`personal` — ALWAYS, do not ask, do not switch**       |
| MCP config  | `~/.hermes/config.yaml` → `mcp_servers.dran` (URL + auth header)   |

**Network path:** NetBird VPN, plain HTTP. If `curl` to that URL fails, the VPN
may be down — check `netbird status` and reconnect before troubleshooting Dran.

**Token hygiene:** `MCP_DRAN_API_KEY` lives in `~/.hermes/.env`. Never echo the
full value. If you need to confirm it exists, print only the first 4 chars:
`echo ${MCP_DRAN_API_KEY:0:4}`. If the endpoint returns 401, re-check the env
var before assuming Dran is broken.

**Notification vs request:** if the JSON-RPC message has a `method` but no `id`, it's
a notification → returns 202 with empty body. Requests return JSON with `result` or
`error`. Session ID is set on `initialize` via the `mcp-session-id` response header.

**Always** set the `Authorization` header. The endpoint will return 401 otherwise.

## Troubleshooting: Tools No Aparecen

Si `tools/list` devuelve menos tools de las esperadas, o el MCP client no ve
las tools nuevas después de un deploy:

### 1. Verificar que el server está corriendo con el código nuevo
```bash
# Health check
curl -fsS http://<dran-host>/health

# Initialize MCP + ver protocolVersion
curl -sS http://<dran-host>/api/mcp \
  -H "Authorization: Bearer $MCP_DRAN_API_KEY" \
  -H "Content-Type: application/json" -H "Accept: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}'

# Listar tools — debe dar 15
curl -sS http://<dran-host>/api/mcp \
  -H "Authorization: Bearer $MCP_DRAN_API_KEY" \
  -H "Content-Type: application/json" -H "Accept: application/json" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | python3 -c "import sys,json; print(len(json.load(sys.stdin)['result']['tools']),'tools')"
```

### 2. Si el server tiene código viejo — reiniciar Dran
```bash
# En el VPS (via SSH o NetBird):
cd /opt/dran
bin/dran stop
bin/server           # o bin/dran daemon

# O si corre via systemd:
sudo systemctl restart dran
```

### 3. Si Hermes no ve las tools del MCP server
Hermes descubre los tools del MCP server al inicio de cada sesión. Si agregaste
tools nuevas al server pero Hermes no las ve:

- **Reiniciar Hermes** (cerrar y reabrir la app, o `/new` para sesión nueva)
- Verificar `~/.hermes/config.yaml` → `mcp_servers.dran.enabled: true`
- Verificar que `mcp_discovery_timeout` en config no sea demasiado bajo (default 1.5s)
- Si el MCP server tarda en responder, subir el timeout:
  ```yaml
  mcp_discovery_timeout: 5.0
  ```

### 4. Si 401 (token inválido)
```bash
# Confirmar que el token existe (solo primeros 4 chars)
echo ${MCP_D...4}

# Si no existe, agregar a ~/.hermes/.env:
echo "MCP_DRAN_API_KEY=<token-de-dran>" >> ~/.hermes/.env

# Reiniciar Hermes después de cambiar .env
```

### 5. Si el VPN (NetBird) está caído
```bash
netbird status          # ver estado
netbird up              # reconectar
# Verificar conectividad
curl -fsS http://<dran-host>/health
```

## Agent Workflow — The Operating Manual

This section is the most important. Read it before doing anything in Dran.

### Rule 0: Search before you create

**Never create a page without first searching for an existing one.** Dran is a
knowledge graph — duplicates are noise. Before `create_page`:

1. `search` with 2-3 keyword variants (the topic, the slug candidate, related terms).
2. If a relevant page exists: `update_page` instead of `create_page`. **Editing is
   better than creating a duplicate.**
3. If you must create (truly new knowledge), pass clean body text. **Do not worry
   about wikilinks** — Dran will auto-create `semantic` relations via embeddings.

### Rule 1: Pick the right page_type

| Type         | When to use                                                    | Subtypes (meta.kind)                                  | Key meta fields                                    |
| ------------ | -------------------------------------------------------------- | ---------------------------------------------------- | -------------------------------------------------- |
| `note`       | Thought, journal, idea, meeting notes, question, quote        | thought, journal, idea, meeting, question, quote     | kind, date, author, attendees                       |
| `concept`    | Abstract idea, technique, pattern, discipline, theory         | technique, pattern, discipline, theory               | kind, domain, parent_concept                       |
| `entity`     | Person, company, product, tool, place, event                  | person, company, product, tool, place, event         | kind, location, external_url, aliases              |
| `reference`  | External source: article, paper, video, podcast, book         | article, paper, video, podcast, book                 | kind, source_url, published_at                      |
| `artifact`   | File or deliverable: document, code, design, file             | document, code, design, deliverable, file            | kind, filename, mime_type, storage_path, sha256     |
| `goal`       | Objective with target date                                     | —                                                    | health (green/yellow/red), target_date, start_date, team |
| `plan`       | Time-horizoned plan                                            | —                                                    | horizon (weekly/monthly/quarterly/yearly), status (draft/active/on_hold/completed/archived), period |
| `todo`       | Actionable item                                               | —                                                    | kanban_status (backlog/this_week/today/in_progress/done/cancelled), priority (low/medium/high/urgent), goal_slug, due_date |
| `comparison` | Side-by-side analysis                                          | —                                                    | entities, criteria, verdict                        |

**Default to `note`** if you genuinely don't know. Promote later via `update_page`
once the knowledge crystallizes. Meta enums are **validated** — passing invalid
values causes changeset errors (see "Meta Validation" section below).

#### Subtypes guide with examples

**Notes (6 subtypes):**
- `thought` — pensamiento suelto, reflexión fugaz. meta: `kind, date`
- `journal` — entrada de diario, qué hiciste hoy. meta: `kind, date, author`
- `idea` — idea para algo (producto, proyecto, contenido). meta: `kind, date, feasibility, impact`
- `meeting` — notas de reunión. meta: `kind, date, attendees, author`
- `question` — pregunta abierta a investigar. meta: `kind, date, resolved`
- `quote` — cita memorable. meta: `kind, date, author, source_ref`

**Concepts (4 subtypes):**
- `technique` — método o práctica específica (ej: Tummo, Trul Khor). meta: `kind, domain, parent_concept`
- `pattern` — patrón de diseño/arquitectura (ej: PubSub, Supervision Tree). meta: `kind, domain, parent_concept`
- `discipline` — disciplina o campo de estudio (ej: Bön, Qigong). meta: `kind, domain, parent_concept`
- `theory` — teoría o framework conceptual (ej: Syntergy Theory). meta: `kind, domain, parent_concept`

**Entities (6 subtypes):**
- `person` — una persona. meta: `kind, aliases, external_url, location`
- `company` — una empresa. meta: `kind, aliases, external_url, location`
- `product` — un producto. meta: `kind, aliases, external_url, location`
- `tool` — una herramienta o tecnología. meta: `kind, aliases, external_url, location`
- `place` — un lugar físico. meta: `kind, aliases, location`
- `event` — un evento (conferencia, meetup). meta: `kind, aliases, external_url, location`

**References (5 subtypes):**
- `article` — artículo web, blog post. meta: `kind, source_url, published_at`
- `paper` — paper académico. meta: `kind, source_url, published_at`
- `video` — video (YouTube, etc.). meta: `kind, source_url, published_at`
- `podcast` — episodio de podcast. meta: `kind, source_url, published_at`
- `book` — libro. meta: `kind, source_url, published_at`

**Artifacts (5 subtypes):**
- `document` — doc, spec, manual. meta: `kind, filename, mime_type, storage_path, sha256`
- `code` — snippet de código, script. meta: `kind, filename, mime_type`
- `design` — diseño, mockup, wireframe. meta: `kind, filename, mime_type`
- `deliverable` — entregable de proyecto. meta: `kind, filename, mime_type`
- `file` — cualquier otro archivo. meta: `kind, filename, mime_type`

**Goals, Plans, Todos, Comparisons** — no tienen subtipos (no `meta.kind`). Tienen
sus propios meta fields específicos (ver tabla de Rule 1).

### Rule 2: Use the right tool for the right job

- **Capturing a thought / idea / meeting notes** → `note` via `create_page`
- **Capturing a person, company, tool** → `entity` via `create_page`
- **Capturing an abstract idea (technique, pattern, theory)** → `concept` via `create_page`
- **Saving a URL (article, video, paper)** → `reference` via `create_page` (with `source_url`) OR `ingest_url` (for files)
- **An action item with status tracking** → `todo` via `create_todo` (NOT `create_page` with page_type=todo — `create_todo` sets the right meta defaults)
- **An objective with a target date** → `goal` via `create_page` with `meta.health` and `meta.target_date`
- **Comparing 2+ things (e.g. Phoenix vs Rails)** → `comparison` via `create_page` with `meta.entities` and `meta.criteria`
- **Saving a PDF / file** → use `ingest_url` (the agent does NOT extract content — that is the agent's job via the resulting page's `source_url`)
- **Delegating a multi-step research/ingest/search task** → `start_agent` with `agent_type=research|ingest|search` and poll with `get_agent_session`

**Hierarchy is a graph, not a tree.** Plans and todos are **optionally** linked to
goals via `meta.goal_slug` (free-form string, no FK). A todo can exist with no
goal, a plan can exist with no goal, and the link is created both by the
`[[wikilink]]` in the body (auto-creates a `related` relation, visible in the
graph) AND by `meta.goal_slug` (textual link that `goal://` resource uses to
group todos/plans under a goal). Either alone works, both together is cleanest.

### Rule 3: Wikilinks and relations are how the graph grows

**Wikilinks** — use `[[slug]]` (or `[[slug|Display Text]]`) inline in the body.
Dran auto-resolves these into `related` relations on `create_page` / `update_page`.

In addition, when the inference API is configured, `Dran.Brain.PageAugmenter`
runs asynchronously after every create/update and can create extra `related`
relations based on semantic similarity. These auto-relations have
`{"auto": true, "confidence": "high"}` in `meta` and are only created when
confidence is high.

**Embeds** — use `![[slug]]` to embed an artifact (renders image / video / audio / PDF
inline). Auto-creates an `embeds` relation.

**Typed relations** — for explicit relationships beyond wikilinks, use
`create_relation`. Relations are **directed** (source → target):

| Type | Cuándo usarlo | Ejemplo |
|------|--------------|---------|
| `related` | Generic connection — ya lo hacen los wikilinks automáticamente. Solo usar `create_relation` si no hay wikilink en el body. | `[[elixir]]` en el body → auto-crea `related` |
| `contradicts` | Source contradice target. Cuando dos pages tienen info conflictiva. | `new-research --contradicts--> old-research` |
| `supersedes` | Source reemplaza/obsoleta target. Nueva versión de un concepto. | `phoenix-1.8 --supersedes--> phoenix-1.7` |
| `part_of` | Source es parte de target. Jerarquía explícita. | `tummo --part_of--> six-yogas-of-naropa` |
| `embeds` | Source embebe target. Ya lo hace `![[slug]]` automáticamente. | `![[tummo-diagram]]` en el body → auto-crea `embeds` |

**Cuándo usar wikilink vs `create_relation`:**
- Si la relación es solo "related" → pon `[[slug]]` en el body (auto-crea)
- Si la relación es `contradicts`, `supersedes`, `part_of` → usa `create_relation` (no se auto-crean con wikilinks)
- Si quieres ambos (related + typed) → wikilink en body + `create_relation` explícito

**Always wikilink to at least one existing page** when creating — this is how the
graph becomes useful. If the page is genuinely isolated, that's a lint signal, not
a feature.

### Rule 4: Slug conventions

- kebab-case, lowercase, ASCII: `learning-elixir`, `bon-religion-overview`
- Unique per context (the `personal` context already has a `learning-elixir` page
  if you've made one — check first)
- Match the title closely. Title: "Learning Elixir" → slug: `learning-elixir`
- For references: derive from the article title or domain
- For entities: full name lowercased: `alvaro-lizama`, `phoenix-framework`

### Rule 5: Use `ingest_url` correctly

`ingest_url` does **NOT** extract or parse the page content. For HTML it saves the
URL as a `reference` page (so the agent can fetch the content later with `web_extract`
and decide what to do). For files (PDF, docs) it downloads and stores them. The
**agent** is responsible for reading the content, summarizing, and linking.

**Workflow:** `ingest_url` → later, fetch the URL yourself via `web_extract` → if
the content is worth a full page, `create_page` with a `note` summarizing + wikilinking
the reference.

- `ingest_url` has **SSRF protection** — blocks localhost, private IPs (10.x,
172.16-31.x, 192.168.x, 169.254.x), CGNAT (100.64-127.x), and IPv6 loopback/link-local.
This means `ingest_url` with `http://localhost:...` **will fail**.

### Rule 5a: Autonomous agents

Use `start_agent` when Álvaro wants a multi-step task, not a single page capture:

- **Research** (`agent_type: "research"`) — searches/scrapes the web, reads current
  pages, and creates new `note`/`reference` pages.
- **Ingest** (`agent_type: "ingest"`) — validates/inspects/downloads a URL and
  creates a `reference` page (useful for files or link capture).
- **Search** (`agent_type: "search"`) — orchestrates semantic + full-text + web
  search, and can create a summary `note`.

Agents run asynchronously on the server. Always call `start_agent`, then poll
`get_agent_session` until `status` is `"done"` or `"error"`. A session keeps running
even if the chat session closes — it is not tied to a specific UI tab.

| Field | Expect |
|-------|--------|
| session_id | UUID returned by `start_agent` |
| status | `running` → `done` or `error` |
| summary | Human-readable result when `done` |
| steps | List of tool calls the agent executed |
| pages_created | Array of `{id, title, slug}` for new pages |

### Rule 6: Update vs create vs rename

- Body changed → `update_page` (auto-bumps version, saves snapshot to `page_versions`).
- Title / tags / meta changed → `update_page`.
- Todo status / priority / due_date changed → **`update_todo`** (merges meta, no need to pass full meta).
- Slug needs to change → use `rename_slug` — it updates the page's slug AND relinks
  all `[[old-slug]]` and `![[old-slug]]` across the entire context automatically.
- If a page is genuinely wrong → note the issue, ask Álvaro before deleting.

### Rule 7: Read before you answer

When Álvaro asks "what do I know about X":
1. `search` with X.
2. For the top 2-3 hits, `get_page` (returns full markdown) to actually read.
3. Synthesize. **Never answer from search excerpts alone** — they are 15-35 word
   snippets, easy to misread.

### Rule 8: Infer when you can, ask when you must

**Infer (don't ask):** page_type from context, slug from title, tags from body, kind
from the kind of note (e.g. meeting notes → kind=meeting), wikilinks from obvious
relations.

**Ask (don't guess):** the context slug if not `personal`, whether a goal needs a
target date, whether something is private vs shareable, deletion of a page, renaming
a slug, anything that touches identity / finances / relationships.

### Rule 9: Lint periodically

`lint` returns orphans, broken wikilinks, stale pages (>90d), contested knowledge.
After a batch of captures, run `lint` and surface the results so Álvaro can decide
what to clean up. Do NOT auto-fix lint output — present it and ask.

### Rule 10: If a tool is missing from MCP, add it — don't document REST workarounds

Álvaro's preference is clear: **the MCP server should be the complete interface**.
If you discover an operation that only exists in REST (delete, relation CRUD,
list with filters, stats, rename), the answer is to **add the tool to `mcp.ex`**,
not to document a curl workaround in the skill.

The pattern for adding a new MCP tool to Dran:
1. Check if `Brain` already has the function (it usually does — `Brain` is the
   public API, REST controllers are thin wrappers).
2. Add the tool definition to the `@tools` array in `lib/dran/mcp.ex`.
3. Add an `execute_tool("name", %{\"context\" => ctx, ...} = args)` clause.
4. Compile: `mix compile --warnings-as-errors`.
5. Test: `mix test`.
6. Update README.md tools table + agent workflow steps.
7. Update `lib/dran_web/live/docs_live.ex` MCP tool cards + Agent Quick Start.
8. Update this skill's Tools Reference + pitfalls if relevant.

**Three documentation surfaces must stay in sync**: `mcp.ex` (code), `README.md`
(repo), `docs_live.ex` (in-app `/docs` page). Forgetting any one causes drift.

Most new tools are 15-20 lines: resolve context → resolve page(s) by slug → call
existing `Brain` function → format the response as a string.

## Autonomous agents

Dran has three ReAct agents (research, ingest, search). They persist every step
and report progress via `agent_sessions` / `agent_steps`. Use them for longer
tasks instead of doing everything in one MCP round-trip.

## Tools Reference (17 MCP tools)

### `search`
Unified knowledge search. `Brain.search/2` automatically picks the best
strategy depending on the query and whether the inference API is configured:

- Short query (≤2 words / ≤25 chars) → FTS + fuzzy (`:fuzzy_fts`)
- Longer meaningful query + inference available → hybrid (`:hybrid`)
- No inference configured → FTS (`:fts`)
- You can override with `"strategy": "fts"`, `"fuzzy"`, `"semantic"` or `"hybrid"`.

Returns compact results: title, slug, type, excerpt, score, source and (for
semantic/hybrid) cosine distance.
```json
{ "query": "elixir pattern matching", "context": "personal", "type": "note", "strategy": "auto" }
```
The `type` filter is optional but **highly recommended** when you know the type —
saves tokens and noise.

### `semantic_search`
Deprecated alias for `search` with `"strategy": "semantic"`. Existing agents keep
working, but prefer `search` for new integrations.
```json
{ "query": "elixir pattern matching", "context": "personal", "type": "note", "hybrid": false }
```
Setting `hybrid: true` is equivalent to `"strategy": "hybrid"`.

### `get_page`
Returns the full markdown body of a page by slug. Use this to actually read content
before editing, summarizing, or referencing.
```json
{ "context": "personal", "slug": "elixir-pattern-matching" }
```
Response: `# Title\n\nBody markdown\n\n---\nType: ... | Tags: ... | Version: N`

### `create_page`
Create a typed page. **Required:** `context`, `title`, `slug`, `page_type`. Optional:
`body`, `tags`, `meta`, `summary`, `owner`, `created_by`. Wikilinks in `body` are
auto-resolved into relations.
```json
{
  "context": "personal",
  "title": "Pattern Matching in Elixir",
  "slug": "elixir-pattern-matching",
  "page_type": "note",
  "body": "The `=` operator in Elixir is actually a match operator. See [[elixir]].",
  "meta": { "kind": "journal", "date": "2026-06-21" },
  "tags": ["elixir", "programming"]
}
```

### `update_page`
Update title, body, tags, or meta. Body change auto-bumps version and saves a
`page_versions` snapshot. Wikilinks in the new body are auto-resolved.
```json
{
  "context": "personal",
  "slug": "elixir-pattern-matching",
  "body": "Updated body with new [[elixir]] examples.",
  "updated_by": "agent"
}
```

### `delete_page`
Delete a page by slug. **Irreversible** — cascades to relations and page_versions.
**Always confirm with Álvaro before deleting.**
```json
{ "context": "personal", "slug": "old-draft" }
```
Response: `Deleted page: <title> (<slug>)` or error.

### `create_todo`
Action item with kanban tracking. **Required:** `context`, `title`, `slug`. Optional:
`goal_slug` (links to a goal), `body`, `priority` (low/medium/high/urgent, default
medium), `kanban_status` (backlog/this_week/today/in_progress/done/cancelled, default
backlog), `due_date` (YYYY-MM-DD).
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

### `update_todo`
Update a todo's kanban status, priority, due date, or goal_slug. **Merges meta** —
you only pass the fields you want to change; existing meta is preserved. This is
the correct way to change a todo's status (not `update_page` which replaces meta).
```json
{ "context": "personal", "slug": "add-lint-mcp", "kanban_status": "done", "priority": "high" }
```
Can also update `title`, `body`, and `tags` (tags replaces existing).

### `create_relation`
Create a typed relation between two pages by slug. Default `relation_type` is
`related`. Use this for explicit relationships beyond what wikilinks auto-create.
```json
{
  "context": "personal",
  "source_slug": "new-research",
  "target_slug": "old-research",
  "relation_type": "supersedes"
}
```
**Relation types:** `related` (default, auto-created by wikilinks), `contradicts`,
`supersedes`, `part_of`, `embeds` (auto-created by `![[embeds]]`).

### `delete_relation`
Delete a relation between two pages by slug pair. Optionally filter by
`relation_type`. Without `relation_type`, deletes ALL relations between the two
pages (both directions). Use `get_links` first to see what exists.
```json
{
  "context": "personal",
  "source_slug": "old-research",
  "target_slug": "new-research",
  "relation_type": "supersedes"
}
```

### `get_links`
Get all inbound + outbound relations for a page. Returns a formatted report.
```json
{ "context": "personal", "slug": "elixir" }
```
Response shows outbound (pages this page links to) and inbound (pages linking to
this page), with relation types. Use this to see backlinks and graph connections.

### `list_pages`
List pages with optional filters. Returns lightweight metadata (no body).
```json
{ "context": "personal", "type": "todo", "status": "this_week", "limit": 20 }
```
Without filters, returns recent pages (default 50). With `type: "todo"` +
`status: "this_week"`, returns the current week's todos. Useful for overview
queries without fetching full content.

### `stats`
Aggregate statistics for a context. Returns total pages, pages by type, todos by
kanban status, orphan count, broken link count, and total relations. Use this for
dashboard-style overviews and weekly reviews.
```json
{ "context": "personal" }
```
Response is a formatted report — no need to parse JSON.

### `lint`
Quality report. Returns:
- **orphans** — pages with no inbound links (consider linking or deleting)
- **broken_wikilinks** — `[[slug]]` pointing to non-existent pages
- **stale** — pages not updated in 90+ days
- **contested** — pages flagged with `kb_contested: true`
```json
{ "context": "personal" }
```

### `rename_slug`
Rename a page's slug and **automatically update all wikilinks `[[old-slug]]` and
embeds `![[old-slug]]` across the entire context** to use the new slug. The page
itself is also updated. Use this when a page was created with a wrong slug.
```json
{ "context": "personal", "old_slug": "lerning-elixir", "new_slug": "learning-elixir" }
```
Response confirms the rename and how many pages were relinked. Fails if the new
slug already exists.

### `ingest_url`
Save a URL. For HTML: creates a `reference` page with the URL. For files: downloads
and stores. **Does NOT extract content** — that's the agent's job later.
```json
{ "context": "personal", "url": "https://example.com/article.html", "slug": "example-article", "tags": ["research"] }
```

### `start_agent`
Start an autonomous agent. Research, ingest, or search. Runs async, persists every
step, and can create pages. Returns the `session_id` you poll with `get_agent_session`.
```json
{
  "agent_type": "research",
  "context": "personal",
  "input": "Yeshe Walmo"
}
```
Supported types: `research`, `ingest`, `search`.

### `get_agent_session`
Poll an agent session by `session_id`. Use it after `start_agent` to wait for
completion in synchronous contexts.
```json
{ "session_id": "04d2..." }
```
Response includes `status`, `summary`, `pages_created`, and `steps`.

## MCP Resources (3)

Read these via `resources/read` with the URI:

| URI                       | Returns                                                      |
| ------------------------- | ------------------------------------------------------------ |
| `page://{ctx}/{slug}`     | Full markdown body of a single page                          |
| `goal://{ctx}/{slug}`     | Goal + all linked todos + plans as JSON                      |
| `wiki://{ctx}/index`      | All pages in the context (slug + title + type) — use for "show me everything" |

**Prefer `wiki://{ctx}/index` over looping `list_pages`** when you need an
overview — it returns the full index in one call.

## MCP Prompts (3)

| Prompt           | Use case                                                       |
| ---------------- | -------------------------------------------------------------- |
| `research_topic` | Scaffold a research page (outline + sources + questions)       |
| `brainstorm`     | Generate 5-10 idea pages around a topic, interlinked           |
| `goal_review`    | Review a goal's status, todos, and plans, suggest next actions |

## Meta Validation (enforced)

`meta` fields are validated by `Dran.Brain.PageMeta` per page type. Passing invalid
enum values causes changeset errors. All enforced enums:

| Page type | Field | Valid values |
| --------- | ----- | ------------ |
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

### Full meta fields by page type

**note:** `kind`, `date`, `author`, `feasibility` (ideas), `impact` (ideas), `attendees` (meetings), `resolved` (questions), `source_ref` (quotes)

**concept:** `kind`, `domain`, `parent_concept`

**entity:** `kind`, `location`, `external_url`, `aliases`

**reference:** `kind`, `source_url`, `published_at`, `content_hash`, `fetched_at`

**artifact:** `kind`, `filename`, `mime_type`, `size`, `storage_path`, `sha256`, `version`

**goal:** `health`, `start_date`, `target_date`, `team`

**plan:** `horizon`, `status`, `period`, `goal_slug`

**todo:** `kanban_status`, `priority`, `due_date`, `goal_slug`, `assignee`, `remind_at`, `acknowledged`, `completed_at`

**comparison:** `entities`, `criteria`, `verdict`

### `update_todo` merge pattern

`update_todo` **merges** meta (starts with existing, overlays changes). `update_page`
**replaces** meta entirely. If a todo has `{kanban_status: "this_week", priority: "high",
goal_slug: "dran-mvp"}` and you call `update_page` with `meta: {kanban_status: "done"}`,
priority and goal_slug are **LOST**. Always use `update_todo` for todo status changes.

## Upload Storage

Files are content-addressed by sha256:
```
priv/static/uploads/{context_id}/{sha256[:2]}/{sha256}.{ext}
```
Served publicly via `/uploads/...` (Plug.Static). Dedup is automatic — same content =
same path. Max size: 100 MiB (`UPLOADS_MAX_SIZE`). Valid extensions: `png jpg jpeg gif
webp svg mp4 webm mov mp3 ogg wav pdf txt md zip csv json html js ts`.

No direct upload via MCP or REST — only via `ingest_url` (remote URLs only, SSRF-protected).

## MCP Tools → Brain Functions

| MCP Tool           | Brain Function Called                                      |
| ------------------ | --------------------------------------------------------- |
| `search`            | `Brain.search/2`                                          |
| `get_page`          | `Brain.get_page_by_slug/2`                                |
| `create_page`       | `Brain.create_page/1` + `Brain.resolve_wikilinks/1`      |
| `update_page`       | `Brain.update_page/2` + `Brain.resolve_wikilinks/1`     |
| `delete_page`       | `Brain.delete_page/1`                                     |
| `create_todo`       | `Brain.create_page/1` (with todo meta defaults)          |
| `update_todo`       | `Brain.get_page_by_slug/2` + `Brain.update_page/2`       |
| `create_relation`   | `Brain.create_relation_by_slugs/4`                       |
| `delete_relation`   | `Brain.delete_relation_by_slugs/4`                       |
| `get_links`         | `Brain.list_relations_for_page/1`                        |
| `list_pages`        | `Brain.list_pages/1`                                      |
| `stats`             | `Brain.stats/1`                                           |
| `lint`              | `Brain.lint/1`                                            |
| `rename_slug`       | `Brain.relink_wikilinks/3` + `Brain.update_page/2`       |
| `ingest_url`        | `Dran.Agent.Ingest.Utils.do_ingest/3`                    |
| `start_agent`       | `Dran.Agent.Engine.run/4`                                |
| `get_agent_session` | `Dran.Repo.get(Agent.Session, id) + preload steps`       |

Brain functions **not** exposed via MCP: `fuzzy_search` (search FTS covers 95%),
`list_contexts` / `create_context` / `delete_context` (admin ops), `graph_data`
(visualization only), `list_log` / `list_page_versions` / `get_page_version` (niche),
`extract_wikilinks` / `extract_embeds` / `resolve_embeds` / `resolve_links` (internal
utilities).

## Setup

### Local dev (repo: `/Users/alvaro/Workspace/repos/dran`)
```bash
mix setup              # deps, db, migrate, assets, seed
mix phx.server         # http://localhost:4000
mix seed               # create default context (idempotent)
mix ecto.migrate       # run pending migrations
mix ecto.reset         # drop + create + migrate + seed (DESTRUCTIVE)
```
- Default ctx: `personal`. Default token: `dran-token` (NEVER use in prod).
- MCP endpoint: `http://localhost:4000/api/mcp`.

### Production (NetBird / VPS via BWS)
- BWS holds `DRAN_API_TOKEN` + `DRAN_PASSWORD` + `SECRET_KEY_BASE` + `DATABASE_URL`.
- Dran ships as an Elixir release with helper scripts in `rel/overlays/bin/`:

```bash
bin/server                          # start Phoenix server (main CMD)
bin/setup                           # create DB + migrate + seed (idempotent, safe every deploy)
bin/migrate                         # pending migrations only
bin/dran eval Dran.Release.seed     # run seeds only
bin/dran eval Dran.Release.migrate  # = bin/migrate
bin/dran daemon                     # background mode
bin/dran remote                     # connect to live node (IEx)
bin/dran stop                       # stop node
```

- `PHX_HOST` is required in `:prod` (no fallback) — set it to the VPN domain.
- For plain-HTTP over NetBird: `PHX_SCHEME=http` + `DISABLE_FORCE_SSL=1` (build env).

### Configuring the MCP client
```json
{
  "mcpServers": {
    "dran": {
      "url": "http://<dran-host>/api/mcp",
      "headers": { "Authorization": "Bearer ${MCP_DRAN_API_KEY}" }
    }
  }
}
```

### Verifying connectivity
```bash
curl -fsS http://<dran-host>/api/mcp \
  -H "Authorization: Bearer $MCP_D...EY" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}'
```

## Common Pitfalls

1. **Creating without searching first.** Always `search` 2-3 variants before
   `create_page`. Duplicates fragment the graph.
2. **Forgetting the context slug.** Default is `personal`. If Álvaro mentions
   another context, use that. Omitting it → 422.
3. **Using `create_page` with `page_type: "todo"`.** Use `create_todo` instead —
   it sets `meta.kanban_status` and `meta.priority` defaults correctly. Manual
   `create_page` will skip those defaults and the todo will be invisible on the
   kanban board.
4. **Wikilinking non-existent slugs.** `[[foo-bar]]` creates a broken link if
   `foo-bar` doesn't exist. The link is stored but the target page is missing —
   `lint` will catch it. Always verify the slug exists or create the target first.
5. **Treating `ingest_url` as content extraction.** It is not. It saves a URL or
   downloads a file. The agent must fetch and read the content separately.
6. **Embedding with `![[slug]]` for non-artifact pages.** Embeds only render for
   `artifact` page types (image/video/audio/PDF). For other types, use a wikilink.
7. **Long bodies without summaries.** Always set `summary` (1-line) for pages
   that the agent or Álvaro will need to find later via `search` — search results
   show the excerpt, but a clear summary helps in listings.
8. **Forgetting `created_by` / `owner`.** The MCP defaults both to `"agent"`. If
   you're acting on behalf of someone, pass `owner: "alvaro"` or `on_behalf_of`.
9. **Updating body when only metadata changed.** Body change bumps `version` and
   creates a `page_versions` snapshot. Pass only the fields you're actually changing.
10. **Assuming `search` is exact match.** It's unified search: picks FTS, fuzzy,
    semantic or hybrid automatically. "programar" matches "programación" via FTS,
    and semantic finds related meanings. Use `"strategy": "fuzzy"` for typos.
11. **Deleting without confirmation.** `delete_page` is irreversible and cascades.
    Always confirm with Álvaro first. After delete, run `lint` to catch orphans.
12. **Using `create_relation` for `related` when a wikilink would do.** If the
    relation is just "related", put `[[slug]]` in the body instead — it auto-creates
    the relation on save. Use `create_relation` only for typed relations
    (`contradicts`, `supersedes`, `part_of`, `embeds`).
13. **Using `list_pages` when `wiki://` resource is enough.** For a full
    overview, `wiki://personal/index` returns everything in one call. Use
    `list_pages` only when you need filtering (type, tag, status).
14. **`update_page` replaces `meta`, doesn't merge.** If a todo has
    `{kanban_status: "this_week", priority: "high", goal_slug: "dran-mvp"}` and
    you call `update_page` with `meta: {kanban_status: "done"}`, the priority and
    goal_slug are LOST. **Use `update_todo` instead** — it merges meta and only
    changes the fields you pass. Only use `update_page` for todos if you need to
    replace the entire meta object deliberately.
15. **No local file upload via MCP.** Neither MCP nor REST has a direct file
    upload endpoint. `ingest_url` only works with remote URLs and has SSRF
    protection (blocks localhost, private IPs, CGNAT). To store a local file:
    upload to a temporary host (0x0.st, S3 pre-signed, etc.) → `ingest_url` with
    that URL. For text/code, put the content directly in the page `body` as an
    `artifact` with `meta.kind: "code"` or `"document"`.
16. **`Error: context 'personal' not found`** → seeds never ran on this VPS.
    Fix once: `bin/setup` or `bin/dran eval Dran.Release.seed`. Don't try to work
    around it by passing a different context.
17. **`Error: source_id: has already been taken`** → you tried to create a
    relation that already exists. `get_links` first. This is **expected and good**
    when re-running — it means the relation is there.

## Verification Checklist

Before any `create_page`:
- [ ] Searched for existing page (2-3 keyword variants).
- [ ] If exists, considered `update_page` instead.
- [ ] Right `page_type` for the knowledge kind.
- [ ] Slug is kebab-case, unique, matches title.
- [ ] Body has at least one `[[wikilink]]` to an existing page.
- [ ] `meta` has the type-required fields (kind, date, kanban_status, etc.).
- [ ] `meta` enum values are valid (see Meta Validation table).
- [ ] Tags are kebab-case, 2-5 tags typically.
- [ ] `summary` set if the page is important for later retrieval.

After any `create_page` / `update_page`:
- [ ] Response confirms version (for updates) or slug (for creates).
- [ ] If errors: changeset errors are surfaced to Álvaro, not silently retried.
- [ ] If inference is configured, `PageAugmenter` may create `related`
  auto-relations asynchronously. That's expected — do not manually recreate them.

After adding/modifying MCP tools:
- [ ] `@tools` array + `@moduledoc` updated in `mcp.ex`.
- [ ] `execute_tool/2` clause implemented.
- [ ] README.md "Available tools" table + "Agent workflow" updated.
- [ ] `docs_live.ex` "Available tools" cards + "Agent Quick Start" updated.
- [ ] `mix compile --warnings-as-errors && mix test` passes.

After batches of changes:
- [ ] Run `lint` to surface new orphans / broken links.
- [ ] Surface lint output to Álvaro, don't auto-fix.

## Quick Recipes

### Capture a thought
```
1. search("...topic...", "personal") → check for duplicates
2. create_page({ title, slug, page_type: "note", body: "Thought... [[related]]", meta: { kind: "thought" } })
```

### Ingest a research article
```
1. ingest_url({ url, context: "personal", tags: ["research"] })
2. Later: web_extract(url) to read the content
3. If worth a full summary: create_page({ page_type: "note", kind: "journal", body: "Summary... [[the-reference-slug]]" })
```

### Add a todo to a goal
```
1. search("...goal name...", "personal", type: "goal") → confirm goal exists
2. create_todo({ title, slug, goal_slug: "<goal-slug>", kanban_status: "this_week", priority: "high" })
```

### Mark a todo as done
```
1. get_page({ context: "personal", slug: "<todo-slug>" }) → confirm it's the right one
2. update_todo({ context: "personal", slug: "<todo-slug>", kanban_status: "done" })
```
`update_todo` merges meta — no need to pass the full meta object.

### Delete a page
```
1. get_page({ context: "personal", slug: "<slug>" }) → confirm exists + show Álvaro
2. ASK Álvaro: "Delete '<title>' (<slug>)? This is irreversible."
3. If confirmed: delete_page({ context: "personal", slug: "<slug>" })
4. lint({ context: "personal" }) → check for orphans left behind
```

### Create a typed relation
```
1. Confirm both pages exist (search or get_page)
2. create_relation({
     context: "personal",
     source_slug: "new-research",
     target_slug: "old-research",
     relation_type: "supersedes"
   })
```
Use cases: `supersedes` (new version replaces old), `contradicts` (conflict),
`part_of` (hierarchy), `embeds` (artifact embedded in note).

### Delete a relation
```
1. get_links({ context: "personal", slug: "<page-slug>" }) → see what relations exist
2. delete_relation({
     context: "personal",
     source_slug: "old-research",
     target_slug: "new-research",
     relation_type: "supersedes"   // optional — omit to delete ALL relations between them
   })
```

### Rename a page slug
```
1. get_page({ context: "personal", slug: "<old-slug>" }) → confirm exists
2. rename_slug({ context: "personal", old_slug: "lerning-elixir", new_slug: "learning-elixir" })
3. Response confirms rename + how many pages were relinked
```

### See what links to a page (backlinks)
```
1. get_links({ context: "personal", slug: "elixir" })
2. Returns outbound (pages this links to) + inbound (pages linking here)
```

### Context overview / stats
```
1. stats({ context: "personal" }) → total pages, by type, todos by status, orphans
2. Use for weekly review or before batch operations
```

### Weekly review
```
1. stats({ context: "personal" }) → high-level overview
2. list_pages({ context: "personal", type: "goal" }) → active goals
3. goal://personal/<goal-slug> for each active goal → status snapshot
4. list_pages({ context: "personal", type: "todo", status: "in_progress" }) → in-progress todos
5. lint({ context: "personal" }) → orphans + broken links to clean up
```

### Scaffold research
```
1. prompts/get("research_topic", { topic, context: "personal" })
2. Follow the prompt's instructions to create outline + sources + questions
3. Capture each source as a reference page, link them in the research note
4. create_relation to link related concepts with typed relations
```

### Capture batch (verified pattern)

For every capture batch, plan BEFORE writing any code:

1. **Pages** — slug + page_type + meta.kind + 1-line description
2. **Wikilinks** — which page wikilinks to which (auto-creates `related`)
3. **Typed relations** — source → target, type (these you must call explicitly)
4. **Validation targets** — which slugs will you `get_links` after

**Order of operations:**
```
1. Create madre/base page first — base of the graph
2. Create children with wikilinks to madre + peers
3. Fix any broken wikilinks surfaced by lint (update_page)
4. create_relation for typed connections
5. get_links on EVERY page, both sides of every relation
6. lint() → 0 orphans, 0 broken
7. stats() → confirm relation count moved as expected
```

**Directional gap to watch:** the most common failure is `get_links(A)` shows
`related → B`, but `get_links(B)` does NOT show `related from A` because B's body
never mentioned A. For every wikilink A → B, ask "should B also mention A?" If
yes, add `[[A]]` to B's body. If no (e.g. B is a foundational concept), leave it —
but document the asymmetry.