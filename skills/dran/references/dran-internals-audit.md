# Dran internals: dead-code audit map & edge-case behavior

Verified against Dran source as of 2026-07-17. Use this reference to avoid
re-grepping during dead-code audits and to know the *tested* edge-case
behavior of key `Brain` functions.

## Wrapper removal candidates (verified July 2026)

These were thin wrappers that only delegated to `Dran.Slug.slugify/1`. They have
been **removed** — call sites now use `Dran.Slug.slugify` (or `Slug.slugify`
via alias) directly. If they reappear, they are dead code again.

| Wrapper | Location | Verdict |
| --- | --- | --- |
| `Brain.slugify_title/1` | `lib/dran/brain.ex` (private) | **Removed.** Only call site was `ensure_title_and_slug/1`. |
| `Ingest.Utils.slugify/1` | `lib/dran/agent/ingest/utils.ex` (public) | **Removed.** Only 3 internal call sites; 0 external callers. |

## Verified-used functions (do NOT remove)

| Function | Why it stays |
| --- | --- |
| `Summaries.summarize_page/1` | Called by `page_edit.ex` `apply_suggestion("summary", ...)` + `summaries_test.exs`. |
| `Summaries.suggest_tags/1` | Called by `page_edit.ex` `handle_event("suggest_tags")` + `artifact_live.ex` + `summaries_test.exs`. |
| `Engine.parse_response/1` / `extract_json/1` | Fallback path for models that don't return native `tool_calls`. Reaches via the `_ ->` branch in `extract_tool_call/1`. Keep unless grep proves all sessions use native tool calls. |
| `Dran.Rerank` module | `use_rerank?()` is read in `brain.ex:191` (brain context flow) and `rerank.ex:28`. **Opt-in** via config (`Dran.Inference.Config.use_rerank?/0`, defaults `false`; env var `DRAN_INFERENCE_USE_RERANK` defaults `"true"`). |

## Other `slugify/1` wrappers that still exist (by design)

Several LiveView modules define their own private `slugify/1` that delegates to
`Dran.Slug.slugify`. These are module-local helpers, not shared public API, so
they are acceptable. If doing a broader cleanup, they could be inlined, but
they do not cause maintenance issues:

- `lib/dran_web/page_edit.ex:397` (`defp slugify`)
- `lib/dran_web/live/page_new_live.ex:288` (`defp slugify`)
- `lib/dran_web/live/ingest_live.ex:342` (`defp slugify`)
- `lib/dran_web/live/todo_live.ex:644` (`defp slugify`)
- `lib/dran/smart_collection.ex:193` (`defp slugify`)
- `lib/dran/summaries.ex:230` (`defp slugify` — different: slugs tag text)

## Edge-case behavior (verified by tests)

### `derive_title/1` (private, `lib/dran/brain.ex`)

- Takes first non-empty line of body, **rejecting** lines that start with
  `![[` (embed) or `[[` (wikilink). Returns `"Untitled"` if all lines are
  embeds/wikilinks or body is empty.
- This was a **bug fix**: previously, `![[some-embed]]` would become the title.

### `resolve_embeds/1`

- Returns `{created_count, not_found_slugs}`.
- Non-existent target slugs go into `not_found` — no broken relation is created.
- Self-references (page embedding itself) are silently skipped (go into
  `not_found`).
- Idempotent: re-running on the same body creates duplicates only if the unique
  constraint on `[:source_id, :target_id, :relation_type]` is violated, which
  it won't be because `create_relation` handles it.

### `reresolve_embeds/1`

- With empty body: deletes all existing `embeds` relations, creates 0 new ones,
  returns `{0, []}`. No error.
- Idempotent on unchanged body (existing relations kept, `resolve_embeds`
  guarded by unique constraint).

### `rename_slug/2`

- Case-only changes ("My-Page" → "my-page") work without unique constraint
  violation on Postgres (case-sensitive collation for `text` type).
- Semantic relations (`related`, `part_of`, etc.) survive renames because they
  reference page **IDs**, not slugs. Only `![[old-slug]]` embed references in
  other pages' bodies are rewritten.
- Runs in a transaction: slug update + body rewrites in other pages.

### `Brain.stats/1`

- With 0 pages in context: returns `%{total_pages: 0, by_type: %{}, recent: [],
  todos_by_status: %{}, orphan_count: 0, total_relations: 0}`. Does not crash.

### `Engine.cancel/1`

- Non-existent `session_id` → `{:error, :not_found}`.
- Running session (in Registry) → `:ok` (sends `:shutdown` exit, marks
  cancelled).
- Session in DB but not running → `:ok` (marks cancelled).

## Audit methodology (reusable for future audits)

1. **Grep before touching.** Use `search_files` with the function name across
   the whole repo to find all call sites. Check both `lib/` and `test/`.
2. **Distinguish public vs private.** `defp` wrappers with a single internal
   call site are safe to inline. `def` wrappers need an external-caller grep.
3. **Verify with `mix compile --warnings-as-errors`** after each removal —
   unused functions surface as warnings.
4. **Don't remove fallback paths** (like `parse_response`/`extract_json`) unless
   you can prove via session data that the code path is never hit. When in
   doubt, leave it.
5. **Document opt-in features** (like `use_rerank?`) in the moduledoc rather
   than removing them.

## Test file locations

- Brain edge-case tests: `test/dran/brain_test.exs` (describe blocks:
  `"edge cases — derive_title ignores embed lines"`, `"edge cases —
  reresolve_embeds with empty body"`, `"edge cases — rename_slug"`, `"edge
  cases — Brain.stats"`, `"edge cases — resolve_embeds with non-existent
  slug"`)
- Engine edge-case tests: `test/dran/agent/engine_test.exs` (describe block:
  `"cancel/1"`)
