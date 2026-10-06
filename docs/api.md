# Dran REST API

Dran exposes a token-protected JSON API under `/api`, plus a public health
check. This is the practical reference: authentication, the authorization
model, every route, and copy-paste examples.

Source of truth: `lib/dran_web/router.ex` and the controllers in
`lib/dran_web/controllers/api/`. If this document and those disagree, the code
wins.

> **Terminology.** Dran is a SINGLE-WORKSPACE instance: there is exactly one
> container (the instance) and every call targets it. History left its marks:
> the API was built around "contexts", then "workspaces", and both words still
> appear in params (`workspace`, `workspace_id`, `context`) and in legacy
> `/api/workspaces/*` paths — they all resolve the same single instance. New
> integrations can omit the parameter entirely.

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
| **Legacy admin token** | instance owner (`is_owner: true`) | the whole instance |
| **Account token** (`users.api_token`) | the user row | everything its owner can read |
| **Group token** (`user_groups.api_token`) | the group (a principal of its own) | EXACTLY what is shared with that group |

There are no per-agent API keys: the credential is the account's ONE token
(shown and regenerated in **Settings → Account**). The agent identity comes
from the `X-Hermes-Agent` header — attribution, not authorization.

### The group token

A group can be a **principal**: it has its own credential, emitted and rotated
from **Admin → Groups → Token** (`?token=<id>`, next to the slug). An agent
holding it is bound to that group — it does not need to configure anything:

- **It writes only there.** With no `scope` the destination IS the group; any
  other destination (`"public"`, `"private"`, another group's slug) is
  `422` and the row is rolled back — never a silent fallback.
- **It reads exactly its group.** `visibility == "shared"` plus a share with
  that group: not the instance's public content, not other people's private
  content, not another group's. Not even when the group's human owner is the
  instance owner — the credential never inherits its owner's privilege.
- **A group without a token authenticates nothing.** Tokens are issued on
  demand; rotating one invalidates the previous immediately.

A missing or malformed header returns:

```json
401  { "errors": { "detail": "missing or malformed Authorization header" } }
```

## Authorization model

- **Read routes** authenticate, then enforce row-level read access against the
  same matrix the write gate uses (`require_read_access` — it resolves the
  instance workspace server-side; the request names no container). Two routes
  are exempt because they are scoped to the identity by construction:
  `GET /api/workspaces` and `GET /api/agent/config`.
- **Row resolution is read-scoped, always.** A `PUT`/`DELETE`/`rename`/`reaugment`
  resolves its row through the reader's scope: a row the caller cannot read is
  `404` (no existence leak), not an overwrite. The same holds for memories
  (`PATCH`/`DELETE`/`feedback`) and for relations — an edge touches TWO pages, so
  both must be readable.
- **Row-level WRITE authority (`ResourceAuthorization.can_write_row?/2`)** —
  resolving a row never meant owning it ("Shares and visibility only move READ
  access"). A row the reader CAN read but does not own answers `403`:
  `{:reader, id}` writes only rows whose `owner_user_id` is `id`; `{:group,
  gid}` writes what its group can read (the group is a principal); `:all`
  (privileged) writes anything it can read. Tasks inherit their goal's owner.
- **Workers and ingest are instance-level.** `POST /api/workers` (and polling
  `/api/workers/:id`) answer `403` for a GROUP credential: the session reads
  and creates instance-wide, which is exactly what a group credential must
  not see. `/api/memory/ingest` resolves its negative-context "known facts"
  with the READER's scope — a foreign private fact never reaches the
  extraction prompt.
- **Write routes** require write authorization for the instance workspace
  (`require_write_access`). Otherwise
  `403 {"errors":{"detail":"Token does not have write access to this workspace"}}`.
- The API never creates, updates or deletes workspaces: the container set is
  instance policy, not an agent capability (those operations live in the admin
  UI).
- **Attribution is server-side** (`Dran.Auth`), never client-settable:
  - `created_by` / `updated_by` — the `X-Hermes-Agent` header when it came
    (the Hermes profile name), otherwise the account email; the legacy admin
    token maps to `admin` / `system`.
  - `agent_name` — the same `X-Hermes-Agent` value, persisted on the written
    content. The header is attribution, not authorization: it never widens
    access.
  - `owner_user_id` — the owner of the credential: for an account token, that
    user. `nil` for the legacy admin token (historical content is
    instance-wide).
- The instance is referenced by **slug** or **UUID** in query param
  `workspace=` (either value resolves it) — and can be omitted: a request that
  names no workspace targets the instance.

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
| GET | `/api/agent/config` | any token | Self-description for agent clients: agent identity + the instance (as a one-entry list) + **effective page types** |

An account token resolves its agent identity here; the legacy admin token gets
a fallback description (header/email, no actor row).

**Page types.** The response reports the instance's **effective** page types —
the 4 built-in types (`note`, `entity`, `concept`, `reference`) plus the
instance's custom types (stored under the legacy key `workspace_page_types`).
Same shape as `Dran.Knowledge.effective_page_types/1`, so an agent discovers
custom vocabulary instead of hardcoding the built-in four. `page_type_defs[].icon`
is always normalized to a `hero-` prefixed name, and `path` is validated on
write (format + reserved route segments) — see [page-types.md](page-types.md)
for the rules a client must satisfy when declaring types in the instance
settings UI.

| Field | Shape | Meaning |
|---|---|---|
| `data.page_types` | `["note", "entity", "concept", "reference", "recipe"]` | effective types of the instance |
| `data.workspaces` | one-entry array | the instance, kept as a list for backward compatibility with plugin builds that iterate it |
| `data.workspaces[].page_types` | same | same list, per entry |
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
    "access_levels": {}
  }
}
```

`access_levels` is always an empty map (the per-key access matrix died with
the per-agent key; kept so old plugin builds that read it keep working without
inventing data). The Hermes memory plugin uses this endpoint to pick its
memory workspace locally and to render the effective page types in its tool
descriptions; with Dran unreachable it falls back to the 4 built-in types.

```bash
curl -s localhost:4000/api/agent/config -H "Authorization: Bearer ***"
```

Any identity with read access can fetch the same vocabulary via
`GET /api/workspaces/:slug/page-types` (the legacy path — any segment
resolves the instance), which returns the same `page_types` /
`page_type_defs` shape:

```json
{
  "data": {
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
}
```

This is what the plugin's `dran_list_page_types` tool calls.

### Instance (legacy `/workspaces` paths)

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/api/instance` | read | The instance — flat, current path |
| GET | `/api/workspaces` | read | Same answer (legacy path) |
| GET | `/api/workspaces/:slug` | read | Same answer (any segment resolves the instance) |
| GET | `/api/workspaces/:slug/page-types` | read | Effective page types (4 built-in ∪ custom) with full definitions |
| GET | `/api/workspaces/:slug/export` | read | Export the instance (by any segment) |

There is no create / update / delete over the API: the container is the
instance, and its settings are instance policy edited in the admin UI. The
legacy paths stay so old plugin builds survive an upgrade.

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
| `workspace` | optional — instance slug or UUID (also accepted as `workspace_id`); omit it and the request targets the instance |
| `type` | page type — one of the instance's effective types (built-in ∪ custom); see [page-types.md](page-types.md) and `GET /api/agent/config` |
| `tag` | filter by tag |
| `status` | filter by meta status |
| `owner` / `created_by` | filter by attribution |
| `limit` | max rows |
| `include=body` | include full bodies (default: lightweight summaries, no body) |

**Show / update / delete** do not require a workspace param: the request
targets the instance. `include=body` on the show route returns the full
body.

**Update** whitelists client-settable fields only:
`title`, `body`, `tags`, `meta`, `summary`, `archived`, `kb_confidence`,
`kb_source_url`, `kb_contested`. Everything else (including `workspace_id`,
`created_by`) is ignored.

```bash
# create
curl -s -X POST localhost:4000/api/knowledge-pages \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"page_type":"note","title":"Hello","body":"# Hi"}'

# read back (verify the write)
curl -s "localhost:4000/api/knowledge-pages/hello?include=body" \
  -H "Authorization: Bearer $KEY"
```

**Body syntax an agent may write.** `body` is markdown. Besides GFM, two
embed idioms are Dran's own and are rendered by the web surface:

| In the body | Renders as |
|---|---|
| `[[slug]]` / `[[slug\|display]]` | a link to another page |
| `![[slug]]` | that page's media inline (image, video, audio, PDF) |
| `![[yt:VIDEO_ID]]` | a YouTube player (nocookie), no key needed |
| `![[vimeo:ID]]` | a Vimeo player, no key needed |
| `![[map:query]]` | a Google Maps frame, no key needed |

A video or map reference must be the canonical `<provider>:<id>` form:
11 url-safe characters for `yt:`, digits for `vimeo:`, a place/query (or a
`!1m…` blob from Maps' *Share → Embed a map*) for `map:`. A full provider URL
works too (`![[https://youtu.be/VIDEO_ID]]`) — Dran normalizes it. Anything
else renders as a broken-embed marker; raw HTML in a body is discarded, so
an `<iframe>` sent through the API never renders.

### Relations

| Method | Path | Auth | Purpose |
|---|---|---|---|
| POST | `/api/relations` | write | Create a typed relation |
| DELETE | `/api/relations/:id` | write | Delete a relation |

`POST` body — by slugs (preferred):

```json
{ "source_slug": "a", "target_slug": "b", "relation_type": "related" }
```

or by ids: `{ "source_id": "...", "target_id": "...", "relation_type": "related" }`.
`relation_type` defaults to `related`. Valid types (13): `related`,
`contradicts`, `supersedes`, `part_of`, `embeds` (manual) + `semantic`,
`mentions`, `works_in`, `has_tier`, `based_in`, `written_in`, `built_with`,
`informs` (machine-owned).

`DELETE` validates read access before deleting.

### Search

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/api/search` | read | Search (`strategy` = `auto`\|`fts`\|`fuzzy`\|`semantic`\|`hybrid`) |
| GET | `/api/search/fuzzy` | read | Trigram (typo-tolerant) search |
| GET | `/api/search/semantic` | read | Vector search (`hybrid=true` for fts + semantic) |

Params: `q` (required), `workspace` (optional — ignored, targets the instance), `type`, `limit`. Semantic/hybrid require
the inference API; without it they return `503` (or degrade to fts, per
strategy).

### Quality / maintenance (read-only)

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/api/lint` | read | Brain hygiene audit (orphans, stale, contested) |

Param: `workspace` (still validated by the controller — pass any value or the
instance's slug).

### Index, graph, log (read-only)

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/api/index` | read | Wiki index — all page slugs + titles + type |
| GET | `/api/graph` | read | Full graph (`{nodes, edges}`) |
| GET | `/api/log` | **owner/admin only** | Activity log (instance telemetry) |

Params: `workspace` (still validated by the controller — pass any value or the instance's slug); `/api/log` also accepts `action`, `limit` (tolerant, capped at 100).

`/api/log` is instance TELEMETRY, not shareable content: it records slugs,
types and authors of every page, including private ones. W2 of the
auditoria-fixes contract (2026-10-05) made it owner/admin-only — a plain token
answers `403`. The web Activity feed shows non-privileged users only the
entries whose page they can actually read.

### Export

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/api/workspaces/:slug/export` | read | Export the instance (any segment resolves it) |
| GET | `/api/export/:workspace/full` | read | Full export by the instance's UUID (sent as a download attachment) |

The `full` export sets `content-disposition: attachment` and includes
the instance, pages, relations, and page versions.

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

All memory writes target the instance (the `workspace` param is accepted for
compatibility and ignored). Params:

- **List:** `status`, `limit`, `offset`.
- **Search:** `q` (required), `limit`.
- **Create:** `content`, `source_session`, `force`.
- **Update:** `content`.
- **Feedback:** `id`, `helpful` (boolean).
- **Ingest:** `transcript` (string or `[{role, content}]`),
  `source_session`. The transcript is **never persisted** — facts are
  extracted server-side and the raw text is discarded.
- **Delete:** `purge` (`true` = permanent).

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
  -d '{"content":"Prefers concise answers."}'
```

### Services (Composio)

La superficie de SERVICIOS. Cada persona conecta SUS apps y su agente las usa a
través de dran: la instancia decide qué se expone (allowlist del owner), la
conexión es del dueño y **solo el dueño ejecuta contra ella**. La key de
Composio es de INSTANCIA y vive server-side: ninguna de estas rutas la devuelve.

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/api/services` | read | Servicios expuestos + el estado real de lo conectado POR EL LECTOR |
| POST | `/api/services/:toolkit/connect` | write | Emite un link de conexión hospedado (vive 10 minutos) |
| DELETE | `/api/services/:toolkit` | write | Desconecta BORRANDO, con revocación upstream (irreversible) |
| GET | `/api/services/:toolkit/tools` | read | El catálogo de ESE toolkit (`?slug=` trae el esquema completo de una tool) |
| GET | `/api/services/search` | read | Descubrimiento por caso de uso (`q=`) |
| POST | `/api/services/execute` | write | Ejecuta una tool contra la conexión del lector |

Identidad: la del token (`users.api_token`). **Ninguna ruta acepta `user_id` ni
`session_id`**: la identidad se resuelve en el borde y la sesión en el contexto,
así que un payload con esos campos no cambia de quién es la sesión.

Estado de una conexión: un **ciclo de vida**, no la validez de una credencial —
`INITIALIZING` → `INITIATED` → `ACTIVE` / `EXPIRED`; `INACTIVE` está
deshabilitada y no ejecuta. La vuelta del consentimiento (`/services/callback`)
no lee ningún parámetro: el estado se consulta al proveedor, nunca se cree de la
query.

```bash
# Lo que este lector tiene conectado, con la identidad del proveedor
curl -s localhost:4000/api/services -H "Authorization: Bearer ***"

# Conectar: devuelve el link hospedado (re-emitir es la única forma de renovarlo)
curl -s -X POST localhost:4000/api/services/gmail/connect -H "Authorization: Bearer ***"

# Descubrir sin cargar el catálogo: por caso de uso…
curl -s "localhost:4000/api/services/search?q=send+an+email+with+an+attachment" \
  -H "Authorization: Bearer ***"

# …y el detalle de un toolkit (o el esquema de UNA tool)
curl -s "localhost:4000/api/services/gmail/tools?slug=GMAIL_SEND_EMAIL" \
  -H "Authorization: Bearer ***"

# Ejecutar
curl -s -X POST localhost:4000/api/services/execute -H "Authorization: Bearer ***" \
  -H "Content-Type: application/json" \
  -d '{"toolkit":"gmail","tool_slug":"GMAIL_SEND_EMAIL","arguments":{"to":"x@y.z"}}'
```

| Result | Status | Body |
|---|---|---|
| lista | `200` | `{"data": [{"toolkit","name","description","connected","status","identity"}], "configured": true}` |
| sin key de instancia | `200` | `{"data": [], "configured": false}` (la lectura lo dice como dato) |
| link | `201` | `{"data": {"toolkit": "gmail", "redirect_url": "https://…", "expires_in": 600}}` |
| ejecución | `200` | `{"data": {"toolkit","tool_slug","log_id","result","error"}}` |
| sin conexión `ACTIVE` | `409` | `{"errors": {"code": "not_connected"}, "toolkit": "gmail", "status": "EXPIRED", "connect_url": "https://…"}` — el link va DENTRO de la respuesta, nunca el error del proveedor |
| fuera de la allowlist | `403` | `{"errors": {"code": "not_allowed"}}` |
| sin key de instancia (escrituras) | `503` | `{"errors": {"code": "not_configured"}}` |

Cada intento de ejecución queda registrado en `service_calls` con el `tool_slug`,
el actor, el `agent_name` del header `X-Hermes-Agent`, el `log_id` del proveedor
y el toolkit; el resultado se guarda truncado y sin credenciales (`blocked`
marca el intento que dran cortó antes de llamar).

### Goals, tasks and plans

El contenedor de trabajo y el plan. `:slug` es **id-o-slug** (el uuid es
canónico; el slug, el atajo legible). Un recurso fuera del alcance del lector es
`404`, nunca `403`: la existencia no se filtra.

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/api/goals` | read | Goals legibles (`status`, `archived`, `limit`) |
| GET | `/api/goals/:slug` | read | Un goal por uuid o slug |
| GET | `/api/goals/:slug/tasks` | read | Las tasks de ESE goal (404 si el goal no es legible) |
| POST | `/api/goals` | write | Crear (sella el dueño de la credencial; `scope` declara el destino) |
| PUT | `/api/goals/:slug` | write | Actualizar (un `scope` presente re-traduce visibilidad + shares) |
| DELETE | `/api/goals/:slug` | write | Borrar el goal, sus tasks (FK `delete_all`) y sus aristas |
| GET | `/api/tasks` | read | Tasks legibles (`goal`, `status`, `assignee`, `archived`, `limit`) |
| GET | `/api/tasks/:id` | read | Una task por uuid |
| POST | `/api/tasks` | write | Crear; **sin `goal`** aterriza en el goal bandeja del dueño |
| PUT | `/api/tasks/:id` | write | Contenido (título, cuerpo, prioridad, fecha, asignado, checklist, recurrencia, archivado) |
| POST | `/api/tasks/:id/move` | write | Columna, posición y/o goal, atómico, con `lock_version` |
| DELETE | `/api/tasks/:id` | write | Borrar la task y sus aristas |
| POST | `/api/capture` | write | Captura rápida: una task en el goal bandeja del dueño |
| GET | `/api/plans` | read | Planes legibles (`status`, `archived`, `limit`) |
| GET | `/api/plans/:slug` | read | Un plan con su checklist y su `progress` DERIVADO |
| POST | `/api/plans` | write | Crear (acepta `checklist`: los pasos nacen con el plan) |
| PUT | `/api/plans/:slug` | write | Actualizar campos (**nunca** el checklist: tiene su puerta) |
| PUT | `/api/plans/:slug/checklist` | write | Reemplaza el array ordenado de pasos |
| DELETE | `/api/plans/:slug` | write | Borrar el plan y sus aristas |
| GET | `/api/groups` | read | Tus grupos: `[{slug, name}]` — con token de CUENTA, las membresías del lector; con token de GRUPO, exactamente su grupo |
| POST | `/api/checklist/toggle` | write | Tacha/destacha UN ítem: `{target: "plan"\|"task", id, index\|text}` |

**El destino de una escritura** se declara con `scope` — `"private"` (default),
`"public"` o `{"group": "<slug>"}` — y el servidor lo traduce a `visibility` +
`content_shares` validando la membresía y fallando cerrado con `422`. No es
estado de ninguna credencial y el cliente **nunca** declara lectura. El grupo se
elige por **nombre** con `GET /api/groups` (`[{slug, name}]` de tus membresías):
el slug es lo que después viaja en el `scope`.

**Excepción — el token de grupo**: esa credencial YA está atada a un destino, así
que no declara `scope`. Sin `scope`, el destino ES su grupo; con un `scope`
distinto del suyo responde `422` y no deja fila huérfana. Es la única credencial
que impone su destino, y lo hace en un solo punto del servidor.

**El destino de una task** es su goal: la task NO declara visibilidad (la hereda
por join). Moverla a un goal que el lector no puede leer es `404` y no mueve la
fila.

**El checklist** es UNO: array jsonb ordenado `[{"text": ..., "done": ...}]`, la
misma forma para el plan y la task. Tachar un ítem reescribe el array (no crea ni
mueve tasks) y respeta `lock_version`: una mano lenta recibe `409`, nunca pisa a
la rápida. `PUT /api/plans/:slug` no toca el checklist — doce puertas para lo
mismo es cómo se diverge (el contrato ya cerró ese caso con `?14`).

```bash
# Captura rápida: sin goal, cae en la bandeja del dueño
curl -s -X POST localhost:4000/api/capture \
  -H "Authorization: Bearer ***" -H "Content-Type: application/json" \
  -d '{"title":"Llamar al contador"}'

# Un goal compartido con un grupo, en la misma escritura
curl -s -X POST localhost:4000/api/goals \
  -H "Authorization: Bearer ***" -H "Content-Type: application/json" \
  -d '{"title":"Lanzamiento","scope":{"group":"equipo"}}'
```

**El plan es una ENTIDAD** (tabla `plans` con dueño y visibilidad), no un tipo de
página: `page_type: "plan"` en `/api/knowledge-pages` es `422`.

### Skills

El catálogo de **instrucciones** que un agente conectado por API descubre y
carga por tool. Un skill es una entidad propia (tabla `skills` con dueño y
visibilidad, como goals y planes), no un tipo de página: **no** entra al grafo,
a la búsqueda semántica ni a los workers.

`:slug` es la dirección del wire (`^[a-z][a-z0-9_-]*$`), **no un id y no se
renombra** — renombrarlo rompe a quien lo tenga cargado. Un skill fuera del
alcance del lector es `404`, nunca `403`: la existencia no se filtra. **No hay
ruta sin credencial**: sin lector no hay scope, así que no existe `.well-known`
ni índice anónimo.

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/api/skills` | read | El catálogo legible, **sin cuerpos** (`visibility`, `order`, `limit`) |
| GET | `/api/skills/:slug` | read | El `SKILL.md` montado (frontmatter + body) + `body` crudo, `version` y `content_hash` |
| POST | `/api/skills` | write | Alta (sella el dueño de la credencial; el slug se deriva del `name` si no viene) |
| PUT | `/api/skills/:slug` | write | Edición versionada del cuerpo/descripción; un `scope` re-traduce el destino |
| DELETE | `/api/skills/:slug` | write | Borrar (sólo el dueño o un lector privilegiado) |

**El contrato de wire** es `name` + `description` (≤ 60 chars) + `body` +
`version` + `content_hash`. La validación es server-side y el changeset es la
ÚNICA puerta (la web y `dran_skill_save` pasan por él): un nombre fuera de
formato, una descripción de más de 60 o un cuerpo fuera de tamaño (1 byte a
100 KB) son `422` **sin dejar fila**; la descripción se valida al guardar, nunca
se trunca al servir.

**La versión es monotónica.** Una escritura que cambia el cuerpo bumpea
`version` y recalcula `content_hash` (sha256 del body, y sólo del body);
reescribir el MISMO cuerpo deja hash y versión iguales. Eso es lo que sostiene
el `unchanged` del agente — sin él habría que re-inyectar el cuerpo en cada
turno.

**El destino** es el mismo vocabulario que páginas, goals y planes:
`private` (default) | `public` | `shared`. `shared` se comparte con
`content_shares` — el mismo diálogo de la casa, `resource_type: "skill"` — y sin
grant lo lee sólo su dueño. La escritura es del dueño (o de un lector
privilegiado): un skill `public` ajeno **se lee, no se edita** (`403`).

```bash
# El catálogo del lector (sin cuerpos)
curl -s localhost:4000/api/skills -H "Authorization: Bearer ***"

# El SKILL.md montado de un slug legible
curl -s localhost:4000/api/skills/revision-semanal -H "Authorization: Bearer ***"

# Alta (el slug se deriva del nombre si no viene) con destino público
curl -s -X POST localhost:4000/api/skills \
  -H "Authorization: Bearer ***" -H "Content-Type: application/json" \
  -d '{"name":"revision-semanal","description":"Cómo revisar la semana","body":"# Pasos","visibility":"public"}'
```

**Las cuatro tools del plugin** (`dran_skills`, `dran_skill`,
`dran_skill_save`, `dran_skill_delete`) son clientes delgados de estas rutas; el
cuerpo viaja por tool y **nunca se copia a disco** (nada de `external_dirs` ni
`register_skill`). La sección de prompt del plugin describe la EXISTENCIA (una
línea por skill, congelada al inicio de la sesión) y manda a `dran_skills` para
el listado vivo.

## Health

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/health` | none | Liveness check |

## Agent tools

The Hermes plugin (`hermes_plugin/dran/`) exposes the same operations as tools
(`dran_*` for knowledge, `dran_memory_*` for memory), each a thin client over the
REST routes above. There is no separate protocol surface: what an agent can do is
what these endpoints expose. See `hermes_plugin/dran/README.md`.

Non-Hermes agents skip the plugin and call these endpoints with their Bearer
token — same auth, same attribution, same visibility rules.