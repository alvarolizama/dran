---
name: dran-relations-flow
description: "Use when linking two Dran pages with a typed relation."
version: 1.0.0
author: Álvaro Lizama
license: MIT
metadata:
  hermes:
    tags: [dran, mcp, relations, graph]
    related_skills: [dran, dran-knowledge-flow, dran-workers-flow]
---

# dran-relations-flow — Link pages with typed relations

Relations are directed and typed: the graph queryability depends on choosing
the right type, not more edges. This flow owns create/delete of relations
between existing pages.

## Entry router

```mermaid
flowchart TD
  Q{What do you need?} -->|"link/unlink two\nexisting pages"| SELF["THIS SKILL\ndran-relations-flow"]
  Q -->|"the target page\ndoes not exist yet"| K[dran-knowledge-flow]
  Q -->|"propose relations for\norphans automatically"| X[dran-workers-flow]

  style SELF fill:#d1fae5,stroke:#059669
```

## Parse contract

CONSUMES: two existing page slugs + the semantic between them. PRODUCES: a
typed directed edge confirmed present by `dran_get_links`. **A relation
created without readback is a mood.**

## Operational flow

```mermaid
flowchart TD
  START([link two pages]) --> S1["RUN mcp_dran_dran_get_links\nsource slug"]
  S1 --> G1{"relation already\nexists?"}
  G1 -->|"yes"| END([idempotent - done])
  G1 -->|"no"| S2["RUN mcp_dran_dran_create_relation\nsource_slug + target_slug + type"]
  S2 --> V1["VERIFY get_links\nreadback: relation present"]
  V1 -->|"missing"| S1
  V1 -->|"holds"| G2{"delete\nrequested?"}
  G2 -->|"yes"| S3["ASK confirm unlink"]
  S3 --> S4["RUN mcp_dran_dran_delete_relation\nsource + target + type"]
  S4 --> V2["VERIFY get_links\nreadback: edge gone"]
  V2 -->|"still present"| S1
  V2 -->|"gone"| END([done])
  G2 -->|"no"| END
```

## Choosing the type (closed enum on MCP)

| Type | Direction means |
| --- | --- |
| `related` | generic link, weak semantics — default |
| `part_of` | source is a component of target |
| `supersedes` | source replaces / outdates target |
| `contradicts` | source disagrees with target |
| `embeds` | source embeds target (usually auto from `![[slug]]`) |

- **The MCP enum is exactly these 5**: `related`, `part_of`, `supersedes`,
  `contradicts`, `embeds`. The schema accepts 13 types server-side, but the
  rest are NOT creatable over MCP: `semantic` is machine-owned (auto-created
  by the augmenter from embeddings), `mentions` comes from the entity
  linker, and `works_in`/`has_tier`/`based_in`/`written_in`/`built_with`
  from props materialization.
- Direction matters: `part_of` from the child TO the parent.
- Duplicate relations on the same pair+type are idempotent — safe to retry.
- `dran_delete_relation` takes an OPTIONAL `relation_type`: **omitting it
  deletes ALL relations between the pair in BOTH directions** — always pass
  the type unless wiping the pair is the intent.
- Missing slug on either side → error, not silent drop: create the page
  first (dran-knowledge-flow).
- Five `meta.props` keys (`role`, `tier`, `location`, `language`,
  `framework`) auto-materialize into edges — prefer them over manual
  relations for taxonomy-style links.

## Pitfalls

- **`related` as a dumping ground** — if you can say `part_of` or
  `supersedes`, say it; generic edges dilute traversal.
- **Inverting direction** — before creating, restate the sentence: "X is
  part of Y" ⇒ source=X, target=Y.
- **Deleting without unlinking knowledge** — an orphaned page after unlink
  should get a link proposal or a home page; check with `dran_get_page`.

## Checklist

- [ ] Both slugs exist (get_links confirms the source side)
- [ ] Type chosen deliberately, not defaulted by laziness
- [ ] Readback confirmed the edge (or its removal)
