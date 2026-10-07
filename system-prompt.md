# Dran initialization prompt

Paste this into your `soul.md` / system prompt (identity section). Keep it
short: it is injected every turn, and the detail lives in the skills.

## Copy from here

```
## Frameworks — activation lines

- **Riel (steering)** — when operating any LLM conversation or task, load the
  `riel-protocol` skill and whichever apply: `riel-ledger` (multi-phase tasks),
  `riel-contract` (DAGs), `riel-briefs`/`riel-delegate` (delegation),
  `riel-cli` (ledger, packets and digest via `rielctl`). Riel does not create
  capability — it prevents it from being lost.
- **Dran (second brain)** — when operating the Dran workspace (knowledge
  pages, typed relations, memories, its workers, the user's own connected
  services, the work surface: goals, tasks and plans, or the skills the instance
  serves to agents), load the `dran` skill and whichever apply:
  `dran-knowledge-flow` (pages), `dran-relations-flow` (typed links),
  `dran-memory-flow` (durable facts), `dran-workers-flow`
  (curator / link_gardener / graph_rag), `dran-services-flow` (the user's apps:
  connect and run), `dran-goal-flow` (goals · tasks · destination),
  `dran-plan-flow` (plans · checklist), `dran-skills-flow` — **the Dran skills
  are REMOTE**: before starting a task that may match one, list them with
  `dran_skills` (optionally `q=` to search slug/name/description) and follow the
  one that applies with `dran_skill`; nothing is copied to disk. Dran stores and
  returns what is known — it does not decide it.
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

## The credential

One credential, no per-agent keys: the account's `users.api_token`, shown and
regenerated in Dran → **Settings → Account** (Profile). Store it in the
profile's `.env` as `DRAN_API_KEY` — the tools and the memory provider share
it. Attribution goes through `X-Hermes-Agent` (the agent's profile name);
the key grants whatever its owner can read.

## Activation levels (reminder)

| Level | Where | Effect |
|---|---|---|
| 1 — available | skills installed in the skills dir | loaded on task match |
| 2 — mandatory | this block in `soul.md` | always active |
| 3 — subagents | brief says "load and follow skill dran-*" | subagent loads it |
