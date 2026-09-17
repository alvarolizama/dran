# Dran REST API

Dran exposes a token-protected JSON API under `/api`, plus a public health
check. This is the practical reference: authentication, the authorization
model, every route, and copy-paste examples.

Source of truth: `lib/dran_web/router.ex` and the controllers in
`lib/dran_web/controllers/api/`. If this document and those disagree, the code
wins.

> **Terminology.** "Workspace" and "context" are the same thing. The API was
> originally built around "contexts"; the UI and the rest of the code now say
> "workspace". Both words appear in params (`workspace`, `workspace_id`,
> `context`) and mean the same entity.

## Base URL

```
http://<host>:<port>/api        # default: http://localhost:4000/api
```

All payloads are JSON. Requests should send `Content-Type: application/json`
and `Accept: application/json`.

## Authentication

Every `/api` route except `GET /health` requires a bearer token:

```
Authorization: Bearer <token>
```

Three token shapes are accepted (`DranWeb.Router.require_api_token/2`):

| Token | Resolves to | Scope |
|---|---|---|
| **Legacy admin token** | instance owner (`is_owner: true`) | every workspace |
| **Per-user token** | the user row | workspaces the user can access (membership ∪ public) |
| **Per-agent API key** | the key itself (no actor row) | only the workspaces granted to the key, each with its own `access_level` (`read` / `write`) |

An API key **does not create an actor**. Its identity is the key: the key
`name` plus the workspaces granted to it in `api_key_workspaces`. It belongs to
the user that created it (`created_by_user_id`).

A missing or malformed header returns:

```json
401  { "errors": { "detail": "missing or malformed Authorization header" } }
```

## Authorization model

- **Read routes** authenticate, then enforce row-level read access against the
  same matrix the write gate uses (`require_read_access`). Two routes are
  exempt because they are scoped to the identity by construction:
  `GET /api/workspaces` (returns only what the token reaches) and
  `GET /api/agent/config` (key-scoped).
- **Write routes** require `write_access` on the key for the target workspace.
  Otherwise `403 {"errors":{"detail":"API key does not have write access to this workspace"}}`.
- **Workspace create / update / delete** additionally require the instance
  owner (`require_admin`).
- **Attribution is server-side** (`Dran.Auth`), never client-settable:
  - `created_by` / `updated_by` — the `X-Hermes-Agent` header when it came
    (the Hermes profile name), otherwise the **key name**; user tokens fall
    back to the user email; the legacy admin token maps to `admin` / `system`.
  - `agent_name` — the same `X-Hermes-Agent` value, persisted on the written
    content. The header is attribution, not authorization: it never widens
    access.
  - `owner_user_id` — the **owner of the key** (`api_keys.created_by_user_id`);
    for a user token, that user. `nil` for keys with no creator and for the
    legacy admin token (historical content is workspace-wide). The `owner`
    field was dropped with the actor model.
- Workspaces are referenced by **slug** or **UUID**. Query param `workspace=`
  accepts either.

## Errors

General shape:

```json
{ "errors": { "detail": "human-readable message" } }
```

Validation failures return `422` with field-keyed messages:

```json
{ "errors": { "title": ["can't be blank"] } }
```

Common status codes: `400` bad request, `401` bad/missing token, `403`
insufficient access, `404` not found, `405` (method not allowed), `409` conflict
(memory near-duplicate), `422` validation, `503` inference not configured.

## Endpoints

### Agent

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/api/agent/config` | agent API key only | Self-description for agent clients: agent identity + reachable workspaces + access levels + **effective page types** |

`GET /api/agent/config` returns `404` for identities that are not an agent API
key (user tokens and the legacy admin token have no agent identity).

**Page types.** Each workspace reports its **effective** page types — the 4
built-in types (`note`, `entity`, `concept`, `reference`) plus the workspace's
own custom types (`workspace_page_types`). Same shape as
`Dran.Knowledge.effective_page_types/1`, so an agent discovers custom
vocabulary instead of hardcoding the built-in four:

| Field | Shape | Meaning |
|---|---|---|
| `data.page_types` | `["note", "entity", "concept", "reference", "recipe"]` | union across every workspace this key reaches |
| `data.workspaces[].page_types` | same | effective types of that workspace |
| `data.workspaces[].page_type_defs` | `[{slug, label, plural, path, icon, color, meta_fields, builtin}]` | full definitions: built-ins first with `"builtin": true`, then the custom ones with `"builtin": false`, in declaration order |

```json
{
  "data": {
    "agent": { "id": "…", "name": "hermes", "display_name": "Hermes" },
    "page_types": ["note", "entity", "concept", "reference", "recipe"],
    "workspaces": [
      {
        "id": "…", "name": "Personal", "slug": "personal",
        "page_types": ["note", "entity", "concept", "reference", "recipe"],
        "page_type_defs": [
          { "slug": "note", "label": "Note", "plural": "Notes", "path": "notes",
            "icon": "hero-pencil", "color": "#60A5FA",
            "meta_fields": [["date", "date", "Date"]], "builtin": true },
          { "slug": "recipe", "label": "Recipe", "plural": "Recipes",
            "path": "recipes", "icon": "hero-book-open", "color": "#F59E0B",
            "meta_fields": [], "builtin": false }
        ]
      }
    ],
    "access_levels": { "personal": "write" }
  }
}
```

The Hermes memory plugin uses this endpoint to pick its memory workspace
locally and to render the effective page types in its tool descriptions; with
Dran unreachable it falls back to the 4 built-in types.

```bash
curl -s localhost:4000/api/agent/config -H "Authorization: Bearer ***"
```

### Workspaces

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/api/workspaces` | read | List workspaces reachable by this identity |
| GET | `/api/workspaces/:slug` | read | Get one workspace |
| POST | `/api/workspaces` | write **+ owner** | Create a workspace |
| PUT | `/api/workspaces/:slug` | write **+ owner** | Update a workspace |
| DELETE | `/api/workspaces/:slug` | write **+ owner** | Delete a workspace |

- `POST` body: `{ "name": "...", "slug": "..." }` (both required).
- `PUT` drops `slug` from the body (slug is immutable via this route).

### Pages

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/api/knowledge-pages` | read | List pages with filters |
| GET | `/api/knowledge-pages/:slug` | read | Get one page |
| GET | `/api/knowledge-pages/:slug/links` | read | Inbound + outbound relations |
| GET | `/api/knowledge-pages/:slug/graph` | read | Subgraph centered on a page (`{node, edges}`) |
| POST | `/api/knowledge-pages` | write | Create a page |
| PUT | `/api/knowledge-pages/:slug` | write | Update a page |
| DELETE | `/api/knowledge-pages/:slug` | write | Delete a page |

**List** (`GET /api/knowledge-pages`) query params:

| Param | Meaning |
|---|---|
| `workspace` | workspace slug or UUID (also accepted as `workspace_id`) |
| `type` | page type — one of the workspace's effective types (built-in ∪ custom); see [page-types.md](page-types.md) and `GET /api/agent/config` |
| `tag` | filter by tag |
| `status` | filter by meta status |
| `owner` / `created_by` | filter by attribution |
| `limit` | max rows |
| `include=body` | include full bodies (default: lightweight summaries, no body) |

**Show / update / delete** require `?workspace=<slug>` (the slug alone is not
globally unique). `include=body` on the show route returns the full body.

**Update** whitelists client-settable fields only:
`title`, `body`, `tags`, `meta`, `summary`, `archived`, `kb_confidence`,
`kb_source_url`, `kb_contested`. Everything else (including `workspace_id`,
`created_by`) is ignored.

```bash
# create
curl -s -X POST localhost:4000/api/knowledge-pages \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"workspace":"personal","page_type":"note","title":"Hello","body":"# Hi"}'

# read back (verify the write)
curl -s "localhost:4000/api/knowledge-pages/hello?workspace=personal&include=body" \
  -H "Authorization: Bearer $KEY"
```

### Relations

| Method | Path | Auth | Purpose |
|---|---|---|---|
| POST | `/api/relations` | write | Create a typed relation |
| DELETE | `/api/relations/:id` | write | Delete a relation |

`POST` body — by slugs (preferred):

```json
{ "workspace": "personal", "source_slug": "a", "target_slug": "b", "relation_type": "related" }
```

or by ids: `{ "source_id": "...", "target_id": "...", "relation_type": "related" }`.
`relation_type` defaults to `related`. Valid types (13): `related`,
`contradicts`, `supersedes`, `part_of`, `embeds` (manual) + `semantic`,
`mentions`, `works_in`, `has_tier`, `based_in`, `written_in`, `built_with`,
`informs` (machine-owned).

`DELETE` validates read access to the relation's workspace before deleting.

### Search

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/api/search` | read | Search (`strategy` = `auto`\|`fts`\|`fuzzy`\|`semantic`\|`hybrid`) |
| GET | `/api/search/fuzzy` | read | Trigram (typo-tolerant) search |
| GET | `/api/search/semantic` | read | Vector search (`hybrid=true` for fts + semantic) |

Params: `q` (required), `workspace`, `type`, `limit`. Semantic/hybrid require
the inference API; without it they return `503` (or degrade to fts, per
strategy).

### Quality / maintenance (read-only)

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/api/lint` | read | Brain hygiene audit (orphans, stale, contested) |

Param: `workspace` (required).

### Index, graph, log (read-only)

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/api/index` | read | Wiki index — all page slugs + titles + type |
| GET | `/api/graph` | read | Full graph (`{nodes, edges}`) |
| GET | `/api/log` | read | Activity log |

Params: `workspace` (required); `/api/log` also accepts `action`, `limit`.

### Export

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/api/workspaces/:slug/export` | read | Export a workspace by slug |
| GET | `/api/export/:workspace/full` | read | Full export by workspace UUID (sent as a download attachment) |

The `full` export sets `content-disposition: attachment` and includes
workspace, pages, relations, and page versions.

### Memory (shared multi-agent store)

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/api/memory` | read | List facts (newest first) |
| GET | `/api/memory/search` | read | Trust-weighted hybrid search |
| POST | `/api/memory` | write | Store a fact (dedupe) |
| PATCH | `/api/memory/:id` | write | Rewrite a fact in place (trust preserved) |
| POST | `/api/memory/feedback` | write | Rate a fact helpful/unhelpful |
| POST | `/api/memory/ingest` | write | Extract facts from a transcript server-side |
| DELETE | `/api/memory/:id` | write | Soft-delete (`superseded`) or hard-delete (`purge=true`) |

Params:

- **List:** `workspace`, `status`, `limit`, `offset`.
- **Search:** `q` + `workspace` (both required), `limit`.
- **Create:** `content`, `workspace`, `source_session`, `force`.
- **Update:** `content`, `workspace`.
- **Feedback:** `id`, `helpful` (boolean), `workspace`.
- **Ingest:** `workspace`, `transcript` (string or `[{role, content}]`),
  `source_session`. The transcript is **never persisted** — facts are
  extracted server-side and the raw text is discarded.
- **Delete:** `workspace`, `purge` (`true` = permanent).

**Dedupe semantics** (`POST /api/memory`): exact hash → semantic duplicate →
semantic near-duplicate grey zone (cosine 0.88–0.95) → create.

| Result | Status | Body |
|---|---|---|
| created | `201` | `{"data": <fact>, "duplicate": false}` |
| exact/semantic duplicate | `200` | `{"data": <existing>, "duplicate": true}` |
| near-duplicate (grey zone) | `409` | `{"near_duplicate": true, "data": <existing>, "submitted": "..."}` |

On `409`, refine the existing fact via `PATCH /api/memory/:id` (trust
preserved) or re-add with `force=true`. Auto-extracted facts from `ingest`
start at trust `0.35` (probation); manual adds start at `0.5`.

```bash
curl -s -X POST localhost:4000/api/memory \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"workspace":"personal","content":"Prefers concise answers."}'
```

## Health

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/health` | none | Liveness check |

## Agent tools

The Hermes plugin (`hermes_plugin/dran/`) exposes the same operations as tools
(`dran_*` for knowledge, `dran_memory_*` for memory), each a thin client over the
REST routes above. There is no separate protocol surface: what an agent can do is
what these endpoints expose. See `hermes_plugin/dran/README.md`.

Non-Hermes agents skip the plugin and call these endpoints with a Bearer key —
same auth, same attribution, same visibility rules.