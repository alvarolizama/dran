# Tuning MCP tool descriptions for agent disambiguation

When an external agent (Hermes, Claude, Cursor) connects to Dran's MCP server,
it uses the `description` field of each tool to decide which one to call. If
descriptions are ambiguous, the agent picks the wrong tool or calls `dran_search`
when it should call `dran_create_page`, etc. This reference captures the guidelines
for writing intent-oriented descriptions that minimize ambiguity.

## The principle

Each description must answer two questions:
1. **When to use THIS tool** (positive trigger).
2. **When NOT to use it** (negative trigger — point to the right alternative).

If two tools could plausibly handle the same request, the descriptions must
cross-reference each other so the agent can disambiguate.

## Verification sources (always read code, never trust existing descriptions)

| What to verify | Where in source |
| --- | --- |
| Enum values for `agent_type` | `start_agent_by_type` function head + the `inputSchema` enum in `@tools` |
| Session status values | `validate_inclusion(:status, ...)` in `lib/dran/agent/session.ex` |
| Default session status on success | `finish_session/3` in `lib/dran/agent/engine.ex` (default arg: `status \\ "done"`) |
| Which agents exist | `defp start_agent_by_type` clauses in `lib/dran/mcp.ex` (NOT just the enum — the dispatch function is the contract) |
| Tool count | Count `"name" =>` entries in the `@tools` list |

**Critical pitfall:** description strings can drift from code. The
`dran_get_agent_session` description said `completed` for months, but the code uses
`done` (verified via `validate_inclusion` + `finish_session` default). Always
check the code before trusting any description that mentions enum values.

## Description patterns that work

### "Use FIRST" pattern (for the entry-point tool)
```
Use this FIRST whenever you need to find anything in the brain...
```
Tells the agent this is the default starting point, not a last resort.

### Cross-reference pattern (for disambiguation pairs)
```
For todos use create_todo instead.          ← in create_page
NOT for notes — use create_page instead.    ← in create_todo
```
```
meta is REPLACED entirely, not merged... For todos, prefer update_todo.   ← in update_page
Meta is MERGED, not replaced... This is the key difference from update_page. ← in update_todo
```

### "Use after X, not before" pattern (for ordering)
```
Use after search or list_pages to actually read content, not before.
```
Prevents the agent from calling get_page before it has a slug.

### Deprecated pattern (for legacy tools)
```
**Deprecated** — use `dran_search` (auto-picks semantic strategy) instead.
```
Leading `**Deprecated**` is the strongest signal to an LLM. Keep it at the
very start of the string.

### Irreversibility pattern (for destructive tools)
```
**This is irreversible** — ... There is no undo.
```
Leading `**irreversible**` + "no undo" gives the agent a hard signal to
confirm before acting.

## Rules (what NOT to change)

- **Do NOT rename tools** — external agents may have them cached. Keep names
  stable; change descriptions only.
- **Do NOT change inputSchemas** — except for enum values that genuinely
  need expanding (e.g. adding new agent types to `agent_type` enum).
- **Do NOT change `execute_tool` logic or dispatch** — description tuning is
  purely a string-level change. Logic changes belong in a separate task.
- **Do NOT update the moduledoc tool list independently** — the one-liners in
  `@moduledoc` (lines ~13-32) must match the `@tools` descriptions. Update both
  in the same pass.

## Workflow

1. Read `lib/dran/mcp.ex` fully — the `@tools` list and `@moduledoc`.
2. Read `lib/dran/agent/session.ex` for `validate_inclusion` (status values).
3. Read `lib/dran/agent/engine.ex` for `finish_session` default status.
4. For each tool, rewrite the description following the patterns above.
5. Update the `@moduledoc` one-liners to match (short versions).
6. Check if `test/dran/mcp_test.exs` asserts on any description or enum strings
   (use `search_files` with `description|enum|agent_type`). If it does, update
   the test assertions.
7. `mix compile --warnings-as-errors` — description-only changes should compile
   clean with zero warnings.
8. `mix test test/dran/mcp_test.exs` — tests should pass unchanged (they don't
   assert on descriptions, but verify anyway).
9. Report: files touched, diff summary, compile output.

## Pitfalls

- **Trusting description text for enum values.** The `dran_get_agent_session`
  description said `completed` but `finish_session/3` uses `done`. The code
  is the source of truth — `validate_inclusion` in the schema and the default
  arg in `finish_session`.
- **Forgetting the moduledoc one-liners.** They drift independently from the
  `@tools` descriptions. Update both in the same pass.
- **Renaming tools "for clarity".** Don't. External MCP clients cache tool
  names. Change the description, not the name.
- **Changing inputSchema fields.** Only the enum list itself should change
  (e.g. adding new agent types). Property names, types, and required arrays
  stay as-is.
