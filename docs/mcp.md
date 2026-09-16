# Dran MCP server

> **Legacy surface.** The Hermes plugin (`hermes_plugin/dran/`) is the primary
> agent surface: it registers the `dran` toolset with `register(ctx)` (search,
> page lifecycle, relations, workers, lint, rename, reaugment, cluster
> summaries) plus the memory provider tools, and every write carries
> `X-Hermes-Agent`. This MCP server stays reachable for MCP clients that are
> **not** Hermes; new tools are added to the plugin, not here.

Dran exposes a [Model Context Protocol](https://modelcontextprotocol.io)
server so agents can read and write the knowledge graph as tools. This is the
practical reference: transport, authentication, the tool/resource/prompt
surface, and JSON-RPC examples.

Source of truth: `lib/dran/mcp.ex` (the server) and
`lib/dran_web/controllers/api/mcp_controller.ex` (the transport). If this
document and the code disagree, the code wins.

## Endpoint & transport

| Method | Path | Behavior |
|---|---|---|
| POST | `/api/mcp` | Send a JSON-RPC message → JSON response |
| GET | `/api/mcp` | `405` — SSE streaming is not implemented |
| DELETE | `/api/mcp` | `200` — terminate session |

Transport: **Streamable HTTP**, MCP spec `2025-03-26`. Responses carry
`mcp-protocol-version: 2025-03-26`; `initialize` also returns an
`mcp-session-id` header.

Requests must send an `Accept` header containing `application/json`,
`text/event-stream`, or `*/*` — otherwise `406`.

## Authentication

`POST /api/mcp` authenticates itself (it does **not** go through the REST
`:api_auth` pipeline, which would reject user tokens):

```
Authorization: Bearer <token>
```

Accepted tokens: the legacy admin token (`is_owner`), a per-user token, or a
context-scoped API key (masquerades as a synthetic user scoped to the key's
workspaces). After auth, the controller enforces per-identity workspace
access; a request naming a workspace the identity cannot reach returns `403`.

Missing/invalid token → `401 {"errors":{"detail":"invalid token"}}`.

## JSON-RPC methods

| Method | Notes |
|---|---|
| `initialize` | Returns server info, capabilities, and the `instructions` block; returns `mcp-session-id` |
| `initialized` | Notification — no response (server replies `202`) |
| `tools/list` | Lists the 18 tools |
| `tools/call` | Invoke a tool by name with `arguments` |
| `resources/list` | Lists the 2 resources |
| `resources/read` | Read a resource by `uri` |
| `prompts/list` | Lists the 1 prompt |
| `prompts/get` | Render the `brainstorm` prompt |

## Tools (18)

`workspace` is the context slug (or default). Tools marked **write** require a
`write_access` key for the target workspace; a read-only key gets a JSON-RPC
error.

| Tool | Required args | R/W | Purpose |
|---|---|---|---|
| `dran_search` | `query`, `workspace` | read | Find anything — pages with title, slug, type, excerpt, distance, source. `strategy` defaults to `auto`. Use FIRST. |
| `dran_list_pages` | `workspace` | read | Lightweight listing (title/slug/type only). Filters: `type`, `tag`, `owner`, `props`, `kind`, `limit`, `offset`. |
| `dran_get_page` | `workspace`, `slug` | read | Full page body by slug. |
| `dran_get_links` | `workspace`, `slug` | read | Inbound + outbound relations of a page. |
| `dran_get_stats` | `workspace` | read | Dashboard numbers: totals, by-type, orphans. |
| `dran_lint_brain` | `workspace` | read | Hygiene audit: orphans, stale pages (>90d), contested knowledge. |
| `dran_get_worker_session` | `session_id` | read | Poll a worker session for status and steps. |
| `dran_create_page` | `workspace`, `page_type` | **write** | Create a typed page. `slug`/`title` derived if omitted. Fails if slug exists. |
| `dran_update_page` | `workspace`, `slug` | **write** | Update page fields. **Replaces `meta` entirely** (not a merge). |
| `dran_delete_page` | `workspace`, `slug` | **write** | Delete a page. **Irreversible** (cascades to relations + versions). |
| `dran_create_note` | `workspace`, `title`, `slug` | **write** | Create a plain note (`kind` is a visual classifier only). |
| `dran_update_note` | `workspace`, `slug` | **write** | Update a note's title/body/tags. **Merges `meta`** (pass only what changes). |
| `dran_create_relation` | `workspace`, `source_slug`, `target_slug` | **write** | Create a typed relation (`relation_type` defaults to `related`). |
| `dran_delete_relation` | `workspace`, `source_slug`, `target_slug` | **write** | Delete relations between a pair. **Irreversible**; omitting `relation_type` deletes ALL relations between the pair, both directions. |
| `dran_rename_slug` | `workspace`, `old_slug`, `new_slug` | **write** | Rename a slug; rewrites all `![[old-slug]]` embeds in the workspace. |
| `dran_reaugment_page` | `workspace`, `slug` | **write** | Re-run augmentation (summary/tags/embedding/relations). Use after major edits. |
| `dran_start_worker` | `worker_type`, `workspace`, `input` | **write** | Start an autonomous worker: `curator`, `link_gardener`, `graph_rag`. |
| `dran_generate_cluster_summaries` | `workspace` | **write** | Generate LLM summaries for all clusters in a workspace. |

The write set is `Dran.MCP.write_tools/0` (11 tools), enforced by
`test/dran/mcp_tool_audit_test.exs`, which asserts every write tool is denied
for a read-only key and allowed for a write-enabled one.

### Embeds

`![[other-slug]]` in a page body is auto-resolved into `embeds` relations on
create/update; stale ones are removed on body update. `dran_rename_slug`
rewrites embed references across the whole workspace.

## Resources (2)

| URI | MIME | Content |
|---|---|---|
| `page://{workspace}/{slug}` | `text/markdown` | Full page content as markdown |
| `home://{workspace}/index` | `application/json` | All pages in a workspace (slug + title + type) |

## Prompts (1)

| Prompt | Arguments | Purpose |
|---|---|---|
| `brainstorm` | `topic` (required), `workspace` (required) | Generate ideas around a topic |

## Server instructions

On `initialize`, the server returns an `instructions` block derived from live
state (the default workspace and the page-type vocabulary from
`Dran.PageRegistry`). It tells the model to target the default workspace when
none is named, lists the page types, notes that write tools need a
write-enabled key, and states that **memory is not part of MCP** (it lives at
`/api/memory`).

## Examples

**initialize**

```bash
curl -si localhost:4000/api/mcp \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"curl","version":"1"}}}'
```

**tools/list**

```bash
curl -s localhost:4000/api/mcp \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
```

**tools/call** — search, then read back a write

```bash
curl -s localhost:4000/api/mcp \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"dran_search","arguments":{"query":"zero trust","workspace":"personal"}}}'
```

**resources/read**

```bash
curl -s localhost:4000/api/mcp \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":4,"method":"resources/read","params":{"uri":"home://personal/index"}}'
```

## Client configuration

```yaml
mcp_servers:
  dran:
    url: http://localhost:4000/api/mcp
    headers:
      Authorization: Bearer <token>
```

See the REST reference in [api.md](api.md) for the `/api/memory` surface (not
exposed over MCP).