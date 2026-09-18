# Dran initialization prompt

Paste this into your `soul.md` / system prompt (identity section). Keep it
short: it is injected every turn, and the detail lives in the skills.

## Copy from here

```
## Frameworks — activation lines

- **Riel (steering)** — when opening or maintaining any LLM conversation or
  task, load `riel-protocol` and whichever apply: `riel-ledger` (state for
  multi-phase work), `riel-contract` (the plan as a mermaid DAG),
  `riel-briefs` / `riel-delegate` (delegation packets), `riel-cli` (drive the
  ledger and instantiate packets with `rielctl`). Riel creates no capability —
  it stops capability from being lost.
- **Dran (second brain)** — when operating the Dran workspace (knowledge
  pages, typed relations, memories, or its workers), load the `dran` skill
  and whichever apply: `dran-knowledge-flow` (pages), `dran-relations-flow`
  (typed links), `dran-memory-flow` (durable facts), `dran-workers-flow`
  (curator / link_gardener / graph_rag). Dran stores and returns what is
  known — it does not decide it.
```

## Why this shape

- **One line per framework** — the soul references skills, it does not embed
  them (embedding desyncs and costs tokens every turn).
- **Trigger-style phrasing** — each line says WHEN to apply, matching the
  skill descriptions so the Level-1 index match fires reliably.
- **Invariant closing line** — the thesis of the framework: Dran stores
  knowledge and memory; it never decides or executes. Execution discipline
  (ledger, briefs, delegation) is Riel, not Dran — so it gets its own line
  rather than a clause inside Dran's.

## Workspace

Every Dran call is workspace-scoped. If your deployment pins a default
workspace, name it in the line — e.g. ``… the Dran workspace `alvaro` …`` —
so the agent does not have to ask. The slug is set in Dran → **Settings →
Agents** (the key's workspace × access-level matrix).

## Activation levels (reminder)

| Level | Where | Effect |
|---|---|---|
| 1 — available | skills installed in the skills dir | loaded on task match |
| 2 — mandatory | this block in `soul.md` | always active |
| 3 — subagents | brief says "load and follow skill dran-*" | subagent loads it |