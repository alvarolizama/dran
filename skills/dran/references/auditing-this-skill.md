# Auditing this Skill for Drift + Installability

Applies when Álvaro asks to review/rewrite this `dran` SKILL.md (or any agent-consumed MCP tool skill). Two goals: (a) keep it a pure agent operating manual, and (b) keep it installable in other agents (Hermes, Claude, etc.) without edits.

## Step 1 — Source of truth first

Never propose from memory. Read the actual server before touching the skill.

- **MCP tools:** `grep -n '"name" =>' ~/Repos/dran/lib/dran/mcp.ex` to enumerate the 18 tools, then read each `description` field. The code is the contract.
- **Endpoint route:** `grep -n "mcp\|Mcp" ~/Repos/dran/lib/dran_web/router.ex`. Do NOT trust what the skill/docs say.
- **Docs/UI strings:** `grep -rn "api/mcp\|/mcp" ~/Repos/dran/lib/dran_web/live/docs_live.ex` — the docs LiveView hardcodes an endpoint.

## Step 2 — The Three Drift Classes

These drift silently and break consumers:

| Class | What drifts | How to catch it |
|---|---|---|
| **Endpoint path** | Skill/docs say `/api/mcp` but router mounts `/mcp` (or vice versa) | Compare router source vs every doc string |
| **Tool count / names** | Skill lists N tools, code has M | Diff the skill's tool table against `grep '"name" =>'` output |
| **Enum / param values** | Skill documents fewer `agent_type` values than the server dispatches | Read the dispatch function (`start_agent_by_type`), not the schema enum |
| **Status values in descriptions** | Description strings mention enum values (e.g. "status: pending/running/completed/failed") that don't match the code | Check `validate_inclusion(:status, ...)` in `lib/dran/agent/session.ex` AND the default in `finish_session/3` in `lib/dran/agent/engine.ex` — the description said `completed` but the code uses `done` |

## Step 3 — Keep it agent-manual-pure

This skill should contain ONLY:

- What Dran is + when to trigger
- Connection/config (endpoint, auth, default context)
- The tools, grouped by **work pipeline** (capture / organize / retrieve / maintain / automate), not alphabetically
- Recipes (step-by-step flows)
- Common mistakes + checklist

**Move out:**

- Project structure, coding conventions, testing → contributor info, not agent-consumer info
- Setup/deployment/env vars → the Dran README or `references/setup.md`

Test: for each section, ask "does the agent need this to choose the right tool and call it correctly?" If no, cut it.

## Step 4 — Keep it installable in other agents

1. **Portable frontmatter** — no machine-specific paths in frontmatter.
2. **Quickstart install section** — exact config block for Hermes `~/.hermes/config.yaml`:
   ```yaml
   mcp_servers:
     dran:
       url: http://<dran-host>/<mcp-endpoint>
       headers:
         Authorization: Bearer ${MCP_...KEY}
   ```
3. **No hardcoded personal paths** in the generic quickstart — use placeholders.
4. **Copy-paste ready** — install by copying the SKILL.md + adding the config block.

## Step 5 — Decision points to surface BEFORE delegating

Surface these trade-offs as explicit questions before launching subagents:

- **Tool naming:** keep generic names (`create_page`) or prefix them (`dran_create_page`)? Clarity vs breaking existing clients.
- **Granularity:** one generic `dran_create_page` with a `page_type` param, or many specific tools? Fewer tools vs clearer intent.
- **Grouping:** alphabetical or by work pipeline? Pipeline matches how agents choose.
- **Aliases:** `semantic_search` was removed in v4.0.0 — `dran_search` with `strategy=auto` (which picks semantic when available) is the replacement. Do not reintroduce a separate semantic tool.

List options + trade-offs and let Álvaro pick before subagents run.

## Pitfalls

1. **Proposing a restructure from memory.** The skill drifts; re-read the current file and server source first.
2. **Trusting the documented endpoint.** Most likely stale fact. Verify against the router.
3. **Removing dev sections without relocating them.** Move useful setup info to `references/setup.md` — don't silently delete knowledge.
4. **Counting tools from the skill instead of the code.** The code wins.
