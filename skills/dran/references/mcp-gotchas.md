# Dran MCP Gotchas

## `dran_update_page` + mermaid = stripped diagrams

**Bug:** Passing `meta` together with `body` in `dran_update_page` causes TipTap to re-parse and strip mermaid block contents, leaving empty ```mermaid blocks.

**Symptom:** After update, mermaid diagrams render as empty boxes or syntax errors.

**Fix:**
1. Pass `body` only (no `meta`) when updating pages with mermaid diagrams.
2. If `meta` also needs updating, do it in a **separate** `dran_update_page` call WITHOUT `body`.

**Wrong:**
```json
{
  "slug": "my-page",
  "body": "...```mermaid\ngraph TD\n  A-->B\n```...",
  "meta": { "tags": ["updated"] }
}
```

**Right (two calls):**
```json
// Call 1: update body only
{ "slug": "my-page", "body": "...```mermaid\ngraph TD\n  A-->B\n```..." }

// Call 2: update meta only
{ "slug": "my-page", "meta": { "tags": ["updated"] } }
```

---

## `dran_update_page` replaces meta entirely

Unlike `dran_update_todo` which **merges** meta, `dran_update_page` **replaces** the entire meta object. Any field you don't pass is lost.

**Fix:** Always read the current page first with `dran_get_page`, merge your changes into the existing meta, then pass the full merged object.

---

## `semantic` relations are automatic

Never call `dran_create_relation` with `relation_type: "semantic"`. The `PageAugmenter` creates these automatically after every create/update based on embedding similarity. Manual creation creates duplicates.

---

## `![[slug]]` embeds only, no `[[slug]]` wikilinks

Plain `[[slug]]` is not parsed. Use:
- `![[slug]]` for embeds (auto-creates `embeds` relation)
- `dran_create_relation` for explicit typed links

---

## Port 4000 stale server

Dran dev often has a stale server on port 4000. Check with `lsof -ti:4000` before assuming the app is down.

---

## Context is `personal` by default

Do not ask Álvaro which context. Do not switch unless explicitly told. All MCP calls default to `personal`.
