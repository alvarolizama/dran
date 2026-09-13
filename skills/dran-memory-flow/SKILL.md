---
name: dran-memory-flow
description: "Use when listing, searching, or deleting Dran agent memories."
version: 1.1.0
author: Álvaro Lizama
license: MIT
metadata:
  hermes:
    tags: [dran, memory, rest, hermes-plugin]
    related_skills: [dran]
---

# dran-memory-flow — Administer shared agent memories

Memory is the **shared recall of agents**, written through the Hermes
plugin (`hermes_plugin/dran/` — `dran_memory_add` tool, auto-capture on
session end). This flow covers ADMINISTRATION only — list, search, delete —
because memory is not part of the MCP surface.

## Entry router

```mermaid
flowchart TD
  Q{What do you need?} -->|"list / search /\
delete memories"| SELF["THIS SKILL\
dran-memory-flow"]
  Q -->|"save a fact, recall at\
turn start"| P["Hermes plugin\
dran_memory_* tools"]

  style SELF fill:#d1fae5,stroke:#059669
```

## Parse contract

CONSUMES: an admin intent over stored memories (find, prune) + a
`DRAN_API_KEY`. PRODUCES: confirmed state via readback (the memory appears/
disappears in `GET /api/memory/search`). **Never writes memories by hand.**

## Operational flow

```mermaid
flowchart TD
  START([memory admin]) --> S1["RUN GET /api/memory/search\
q + workspace, Bearer key"]
  S1 --> G1{"target memory\
found?"}
  G1 -->|"no"| S2["RUN GET /api/memory\
workspace - browse list"]
  G1 -->|"yes"| G2{"delete\
requested?"}
  S2 --> G2
  G2 -->|no| END([reported])
  G2 -->|yes| G4{"soft supersede or\
permanent purge?"}
  G4 -->|"obsolete"| A1["ASK confirm delete -\
durable data, irreversible"]
  G4 -->|"purge"| A2["ASK confirm PURGE -\
hard delete, NO undo"]
  A1 --> S3["RUN DELETE /api/memory/:id?workspace=WS\
write_access key required"]
  A2 --> S3P["RUN DELETE /api/memory/:id?purge=true&workspace=WS"]
  S3 --> V1["VERIFY GET search\
readback: gone from results"]
  S3P --> V2["VERIFY row gone -\
Repo.get returns nil"]
  V1 -->|"still present"| S1
  V2 -->|"still present"| S1
  V1 -->|"gone"| END([done])
  V2 -->|gone| END([done])
```

## The REST surface (no MCP)

| Route | Method | Access |
| --- | --- | --- |
| `/api/memory` | GET | key valid (read always allowed) |
| `/api/memory/search` | GET (`q`, `workspace`, `limit`) | key valid |
| `/api/memory` | POST | `write_access` — **plugin's job, not this flow's** |
| `/api/memory/feedback` | POST | `write_access` — plugin's job |
| `/api/memory/ingest` | POST | `write_access` — plugin's job (session end) |
| `/api/memory/:id` | DELETE | `write_access` — soft-delete (superseded); **API keys MUST pass `?workspace=<slug>`** |
| `/api/memory/:id?purge=true&workspace=<slug>` | DELETE | `write_access` — **hard delete, permanent** |

- Base URL is the profile's Dran (`$HERMES_HOME/dran_memory.json →
  base_url`); same `DRAN_API_KEY` as MCP.
- `created_by` on every memory is attributed server-side from the key's
  actor — never trust a client-set author.

## Pitfalls

- **`POST /api/memory` by hand to "save" something** — writes belong to the
  plugin so the provenance (`X-Hermes-Agent`, actor) stays honest; a
  manual POST forges the author's context.
- **Purge ≠ delete** — plain DELETE soft-supersedes (status flips, row
  stays, excluded from search); `?purge=true` hard-deletes the row, and
  the fact can be re-stored later (no dedupe ghost).
- **DELETE /api/memory/:id without `?workspace=<slug>` 403s for API
  keys** — the write-access plug resolves the workspace from
  `conn.params` only; with no `workspace` param it gets `nil` →
  `"API key does not have write access to this workspace"` even for a
  valid write key. Query params populate `conn.params`, so appending
  `&workspace=<slug>` fixes it.
- **GET /api/memory caps at 100 rows regardless of `limit`** — paginate
  with `offset` (loop until a page returns < 100) before claiming a
  total count; the first page lies about the size of the workspace.
- **No bulk purge endpoint** — full wipe = per-id loop of
  `DELETE /:id?purge=true&workspace=<slug>`, then re-enumerate until 0
  remain; the UI-only "Borrar obsoletos" covers superseded rows only.
- **Deleting the whole workspace's recall on a bad review** — delete by
  specific id, one confirmation each.
- **Expecting `dran_memory_*` MCP tools** — zero on MCP; only the plugin
  and REST exist.
- **Confusing memory with page knowledge** — memories are agent-facts
  (dedupe + trust server-side); knowledge that humans read goes through
  dran-knowledge-flow.

## Checklist

- [ ] Admin-only: no manual POST/ingest from this flow
- [ ] Search + browse to locate exact ids before any delete
- [ ] Delete confirmed by the human, verified by readback (gone)
- [ ] Purge (`?purge=true`) explicitly flagged as permanent to the human
- [ ] API-key DELETEs carry `?workspace=<slug>` (else 403)
- [ ] Totals counted with offset pagination (limit caps at 100)
