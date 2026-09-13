---
name: dran-knowledge-flow
description: "Use when creating or editing Dran knowledge pages via MCP."
version: 1.0.0
author: Álvaro Lizama
license: MIT
metadata:
  hermes:
    tags: [dran, mcp, knowledge, pages]
    related_skills: [dran, dran-relations-flow]
---

# dran-knowledge-flow — Create and edit knowledge pages

Pages are the unit of knowledge: `note`, `idea`, `project`, `knowledge`,
`technical`, `entity`, `concept`, `reference`.
This flow owns the write loop: search first,
then create or update, then verify by readback.

## Entry router

```mermaid
flowchart TD
  Q{What do you need?} -->|"write/read/rename\na page"| SELF["THIS SKILL\ndran-knowledge-flow"]
  Q -->|"typed link between\ntwo pages"| R[dran-relations-flow]
  Q -->|"connection, auth,\nreadback rule"| D[dran — main]

  style SELF fill:#d1fae5,stroke:#059669
```

## Parse contract

CONSUMES: a knowledge item to persist (title, body, type) or a query
against existing pages. PRODUCES: a page whose state is confirmed by
`dran_get_page` readback. **A write without readback is not done.**

## Operational flow

```mermaid
flowchart TD
  START([knowledge task]) --> S1["RUN mcp_dran_dran_search\nquery + workspace + strategy"]
  S1 --> G1{"page exists\nwith this slug?"}
  G1 -->|"no"| S2["RUN mcp_dran_dran_create_page\nworkspace + page_type + body"]
  G1 -->|"yes"| S3["RUN mcp_dran_dran_update_page\nslug + changed fields"]
  S2 --> S4["RUN mcp_dran_dran_reaugment_page\nslug - refresh embeddings"]
  S4 --> V1["VERIFY dran_get_page\nreadback: title + body"]
  S3 --> V1
  V1 -->|"mismatch"| S1
  V1 -->|"holds"| G2{"slug rename\nneeded?"}
  G2 -->|"yes"| S5["ASK confirm rename -\nbacklinks break"]
  S5 --> S6["RUN mcp_dran_dran_rename_slug\nold_slug + new_slug"]
  S6 --> V1
  G2 -->|"no"| G3{"delete\nrequested?"}
  G3 -->|"yes"| S7["ASK confirm delete -\nirreversible"]
  S7 --> S8["RUN mcp_dran_dran_delete_page"]
  S8 --> V2["VERIFY dran_get_page\nreadback: not found"]
  V2 -->|"still present"| S1
  V2 -->|"gone"| END([done])
  G3 -->|"no"| END
```

## Notes on the calls

- `page_type` enum comes from `Dran.PageRegistry` (8 types): `note`
  (free-form capture), `idea` (idea/question/hypothesis/spark), `project`
  (project/plan/goal/milestone — with horizon/status meta), `knowledge`
  (quote/summary/highlight/excerpt), `technical` (code/snippet/debug/
  recipe/config/command/template/pattern/method), `entity`, `concept`
  (free), `reference`.
  `dran_create_note` / `dran_update_note` are title+slug shorthands for
  `note`.
- Search `strategy` (not `mode`): `auto / fts / fuzzy / semantic / hybrid`.
  Run search before any create — duplicates are the main graph rot.
- `summary` on pages is **machine-owned** (set via create/update/nightly
  job; the UI never edits it). Keep it a real one-liner.
- Confidence levels for claims recorded in pages: low / medium / high /
  verified.
- After create/update with body changes, `dran_reaugment_page` refreshes
  embeddings — skip it only when the body is untouched.
- `dran_list_pages` takes optional type/status filters for audits;
  `dran_get_stats` for counts; `dran_get_page` for one slug.

## Pitfalls

- **Creating a page that already exists under another slug** — search
  variants (accents, hyphens) first.
- **Renaming slugs casually** — embeds (`![[slug]]`) and backlinks break;
  ASK, rename, then re-read `dran_get_links` both sides.
- **Trusting the create `ok`** — verify with `dran_get_page`; the readback
  IS the done-check.

## Checklist

- [ ] Search ran before write; slug confirmed fresh or update chosen
- [ ] Write + reaugment done
- [ ] Readback verified (get_page; for delete: gone)
- [ ] Rename/delete went through ASK
