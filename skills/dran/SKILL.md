---
name: dran
description: "Use when operating Dran over MCP — router and shared rules."
version: 11.0.0
author: Álvaro Lizama
license: MIT
metadata:
  hermes:
    tags: [dran, second-brain, mcp, knowledge-graph]
    related_skills: [dran-knowledge-flow, dran-relations-flow, dran-workers-flow, dran-memory-flow]
---

# dran — MCP reference + suite router

Main skill of the Dran suite. Load it first: it routes to the per-action
flows and holds what every flow shares — connection, auth, the readback
rule. Dran is the second brain: knowledge (pages) and memory. The agent's
local execution discipline (ledger, briefs, delegation) is riel — this
suite owns only the MCP/REST call sequences.

## Entry router

```mermaid
flowchart TD
  Q{What do you need?} -->|"MCP tools, connection,\ngeneral rules"| SELF["THIS SKILL\nmain dran"]
  Q -->|"create/edit/query\nknowledge pages"| K[dran-knowledge-flow]
  Q -->|"link pages\ntyped relations"| R[dran-relations-flow]
  Q -->|"run curator/link_gardener/\ngraph_rag"| X[dran-workers-flow]
  Q -->|"list/search/delete\nmemories"| M[dran-memory-flow]

  style SELF fill:#d1fae5,stroke:#059669
```

Run ONLY the flow you landed on. If the diagram sends you to another skill,
**stop here** and hand off — don't absorb that work.

## Connection (once per Hermes profile)

- `config.yaml` → `mcp_servers.dran: { url: "http://localhost:4000/api/mcp",
  headers: { Authorization: "Bearer ${DRAN_API_KEY}" } }`. The secret lives
  ONCE in the profile's `.env` (`DRAN_API_KEY`); the memory plugin resolves
  the same var — one key, one actor. Restart the session after adding the
  server (no hot-reload).
- Hermes registers each tool as `mcp_<server>_<tool>` → with server `dran`,
  calls look like `mcp_dran_dran_search`.
- **One key = one actor.** Attribution (`owner`/`created_by`) is
  derived server-side from the key — never client-settable.
- **Write gate**: keys with `write_access: false` get `403` on every write
  tool (`@write_tools` in the server: pages, relations, workers).
- **Memory is NOT in the MCP surface** — REST `/api/memory` + Hermes plugin
  only. Do not look for `dran_memory_*` MCP tools.
- MCP resources: `page://<ws>/<slug>`, `home://<ws>/index`. Prompts:
  `brainstorm` (topic).

## General rules (every flow obeys them)

```mermaid
flowchart LR
  W["Any write tool\ncalled"] --> G{"MCP said ok?"}
  G -->|"no"| F["Fix params /\ncheck write_access"] --> W
  G -->|"yes"| V["VERIFY readback\nget_page / get_links /\nGET list"]
  V -->|"state holds"| E([done])
  V -->|"state missing"| W
```

- **A write is not done until a readback confirms the state.** The MCP `ok`
  is transport-level, not state-level.
- Slugs are canonical identifiers; a slug not found is an error, never a
  silent drop. Derive slugs from titles, lowercase-hyphen.
- Irreversible operations (delete page/memory, rename slug) require an
  explicit human confirmation first — every flow marks them with ASK.

## The flows of the suite

| Flow | When to load it |
| --- | --- |
| `dran-knowledge-flow` | Create, update, search or rename pages (note, idea, project, knowledge, technical, entity, concept, reference…) |
| `dran-relations-flow` | Link two pages with a typed relation |
| `dran-workers-flow` | Fire and poll curator / link_gardener / graph_rag |
| `dran-memory-flow` | Administer shared agent memories (REST) |

## Pitfalls

- **Absorbing a flow you were routed away from** — the router is the
  contract; hand off.
- **Reading the tool list off the MCP `initialize` output once and never
  again** — the surface grows; `dran_list_*` and the server docs are the
  truth, this suite is the map.
- **Looking for `dran_memory_*` MCP tools** — memory is REST/plugin only.

## Cross-references

- Server-side surface (tool definitions, write gate): `lib/dran/mcp.ex`
  in this repo
- Verb/graph conventions the flow DAGs follow: `riel-contract`
