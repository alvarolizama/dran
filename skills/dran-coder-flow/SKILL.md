---
name: dran-coder-flow
description: "Use when executing a Dran dev todo (code) — opens with riel-protocol + ledger from the todo, human-decides mode (test-first / research / autonomous TDD), gates before commit. Triggers on execute/implement todo."
version: 2.1.0
author: Álvaro Lizama
license: MIT
metadata:
  hermes:
    tags: [dran, coding, execution, subagents, gates, mermaid, riel]
    related_skills: [dran, dran-todo-flow, dran-planning-flow, riel-protocol, riel-ledger, riel-contract, riel-delegate, riel-briefs, git-workflow]
---

# dran-coder-flow — Execute a development todo (code)

This skill takes a Dran development todo (level 3 of `dran-todo-flow`:
`## Goal` + `## Phases` with code) and **executes** it: it opens with
`riel-protocol` + a ledger created from the todo's info, lets the **human**
pick the execution mode (test-first / research / autonomous TDD), does
shaping if it arrived as a draft, dispatches subagents per phase, validates
gates (with smoke **before** commit) and closes with real evidence.

## Layer separation (riel)

`dran-coder-flow` does **not reimplement the ledger** — it delegates local state to
`riel-ledger`, and only acts as the **adapter** to Dran:

| Layer | Skill | Responsibility |
|---|---|---|
| Communication (anchored opening + maintenance) | `riel-protocol` | steers every interaction, from the first turn to the subagent briefs |
| Local state (✓NN, recovery, done-check) | `riel-ledger` | `.riel/ledger.md` — never touches Dran |
| Orchestration (mode choice, shaping, subagents, gates) | `dran-coder-flow` | execute the todo |
| Dran adapter (minimal) | `dran-coder-flow` | `pull` (read todo) + `push-phase` (checkbox) + `push-close` (status done) |

**Hard rule:** the `✓NN` (evidence with verifier + coverage) lives ONLY in the
local ledger. Dran only receives *checked checkboxes* and *status* — never
accumulated evidence in the body.

## Entry router

```mermaid
flowchart TD
  Q{What do you need?} -->|"Execute a dev\ntodo (code)"| SELF["THIS SKILL\ndran-coder-flow"]
  Q -->|"WRITE the todo\n(templates, levels)"| TF[dran-todo-flow]
  Q -->|"The plan that groups\nthe todos"| PLF[dran-planning-flow]
  Q -->|"MCP tools, page types,\nconnection"| D[dran — main]

  style SELF fill:#d1fae5,stroke:#059669
```

If the todo is of another type (manual, non-code research), it is not for this
skill — go back to `dran-todo-flow` or execute manually.

## Operational flow — follow this DAG to the letter

```mermaid
flowchart TD
  START[Assigned development todo] --> PULL["PULL: dran_get_page\nread the FULL todo"]
  PULL --> PROTO["OPEN riel-protocol\nanchored opening from ## Goal\nWe need + minimal surface"]
  PROTO --> LEDGER["CREATE .riel/ledger.md\n(via riel-ledger)\nGoal ← ## Goal · Source ← todo:slug"]
  LEDGER --> SHAPE{"level 3?\n## Phases with DAG\n+ Scope + context"}
  SHAPE -->|"No (level 1 draft)"| DISCOVER["SHAPING: analyze real codebase\n+ clarify confirmation"]
  DISCOVER --> EXTEND["Extend phases → level 3\n(via dran-todo-flow)"]
  EXTEND --> MODE
  SHAPE -->|"Yes"| MODE{"Execution mode\nHUMAN decides\n(agent suggests)"}
  MODE -->|"1. Test-first TDD\n(from ## Verification + ## Goal)"| TEST1["write failing test\n+ clarify validation"]
  TEST1 --> LOOP
  MODE -->|"2. Research codebase"| RES["technical discovery\ncomplement todo + ledger Goal\nno implementation code"]
  RES --> MODE
  MODE -->|"3. Autonomous TDD"| LOOP{"for each phase\nper ## Phases"}
  LOOP --> BRIEF["Subagent brief\n(Scope + Context + DAG\n+ protocol opening)"]
  BRIEF --> DISPATCH["dispatch\nparallel if disjoint\nserial if they share a file"]
  DISPATCH --> GATE{"VERIFY before commit\ncompile + test + smoke\n+ format + diff ⊆ scope"}
  GATE -->|"fails"| REDISPATCH["re-dispatch with\nthe error as context"]
  REDISPATCH --> DISPATCH
  GATE -->|"passes"| CONFIRM["clarify commit\n(after green verify)"]
  CONFIRM --> COMMIT["commit"]
  COMMIT --> VNN["append ✓NN to local ledger\n(via riel-ledger)"]
  VNN --> CHECK["check the phase checkbox\n(push-phase → Dran)"]
  CHECK --> LOOP
  LOOP -->|"last phase"| DONE{"done-check\n(via riel-ledger)"}
  DONE --> CLOSE["status done\n(push-close → Dran)"]

  style PROTO fill:#d1fae5,stroke:#059669
  style LEDGER fill:#d1fae5,stroke:#059669
  style DISCOVER fill:#fef3c7,stroke:#d97706
  style MODE fill:#fef3c7,stroke:#d97706
  style DISPATCH fill:#dbeafe,stroke:#2563eb
  style GATE fill:#fef3c7,stroke:#d97706
  style CLOSE fill:#d1fae5,stroke:#059669
```

## Parse contract

### What this skill CONSUMES
- A Dran development todo (level 3, or a level 1 draft that will get shaping)
  with `## Goal` + `## Phases` + `## Verification`
- Access to the real repo where it runs (path, working branch)

**Todo contract limits** — if violated, go back to `dran-todo-flow` to
split/fix it; never execute it as-is:

| Limit | Rule |
|---|---|
| Size | todo body **6–8 KB max**. Bigger = it must be split before execution. |
| Verifiability | every `## Verification` criterion must be **verifiable by a human** — a person can check it by hand (run a command, see a UI behavior, read an output). |

### What this skill PRODUCES

| # | Artifact | Purpose |
|---|-----------|-----------|
| 1 | Phases implemented with clean commits | Real, verified code |
| 2 | Todo checkboxes checked per phase | Visible progress in Dran |
| 3 | Gates passed (compile, test, smoke, format, diff) | Quality evidence |
| 4 | Todo in `done` via `dran_update_todo` | Honest close |

**Without real evidence there is no `done`** — red tests, warnings, failed
smoke, or out-of-scope diff = the phase did NOT pass, it gets re-dispatched
with the error.

## Opening — riel-protocol + ledger (mandatory, first, from the todo)

The flow opens with the todo's info — never with the plan, the repo, or
assumptions. Two mandatory steps, in this order, before any analysis or code:

1. **Open with `riel-protocol`**: anchored opening built from the todo's
   `## Goal` — "Necesitamos <goal>…" + short stable persona + minimal surface
   (only what the first action needs: the todo + the repo path). Keep the
   protocol alive for the **whole flow**: every functional statement
   discharges into an action, a check, or a closure; doubt loops without
   action are a protocol break → return to "Necesitamos…" + the next concrete
   action.
2. **Create the ledger with `riel-ledger`**: `.riel/ledger.md` from the todo's
   info — `Goal` ← the todo's `## Goal` (verbatim), `Source` ← `todo:<slug>`,
   `Phase` ← first phase without a checkbox, `Next` ← first action. Created
   **before** shaping, not after.

Both live for the entire flow: the protocol steers every interaction
(including subagent briefs — open their `goal` with the shared objective),
the ledger carries the verified state across phases. Make sure `.riel/` is in
the worktree's `.gitignore` before committing anything.

## Shaping — from draft (level 1) to level 3

A todo can arrive at level 1 (draft, phases in prose). **It is not rejected —
it is extended** by analyzing the real codebase. Shaping is the *senior
reviewing a junior* pattern: nothing is invented, everything is grounded in
evidence.

### Procedure (technical discovery)

1. Read the todo's `## Goal` and turn the functional outcome into concrete
   questions: entry points, domain modules, data paths, interfaces, tests,
   reusable patterns, migrations, authorization, risks.
2. Use `search_files` by **domain and behavior names**, not only by the
   proposed module name.
3. Use `read_file` on every relevant file, citing `path:line` — never cite
   search snippets as if the full implementation had been read.
4. Build the evidence table:

   | Area | Evidence (repo) | Finding | Proposed change | Risk |
   |---|---|---|---|---|
   | `<area>` | `<path:line>` | `<observed behavior>` | `<concrete approach>` | `<risk or none>` |

5. **Confirmation `clarify`** with the proposal (scope, sequence, test
   strategy, open assumptions, no-goals). Options like:

   ```json
   {
     "question": "I reviewed the codebase. How should I proceed with the shaping?",
     "choices": [
       "Approve the plan and extend the phases",
       "Reduce scope",
       "Adjust the approach (give me your correction)",
       "Stop — information is missing"
     ]
   }
   ```

6. After confirmation, **extend the phases** to level 3 (per phase: `Scope` +
   `Context (what exists now)` + `What changes` + `Instruction DAG`) and
   update the todo via `dran-todo-flow`. Only then present the execution
   modes — the human picks (see Execution mode).

**Hard rule:** if the repo's reality doesn't match what the todo says
(renamed module, moved function), do NOT improvise — report the discrepancy
and `clarify` the correction.

## Execution mode — the human decides (agent only suggests)

Before any implementation code is written, the human picks the entry mode.
The agent **never** chooses it: it presents the modes with a suggested
default (marked as such) and `clarify`s. The three modes:

| Mode | What happens | Source |
|---|---|---|
| 1. **Test-first TDD** | Write the failing test derived from the todo's `## Verification` + `## Goal`, validate it with the human (`clarify`: what is tested, what is expected), then the phase loop implements until green. | `## Verification` + `## Goal` |
| 2. **Research codebase** | Technical discovery — same procedure as Shaping, grounded in `path:line` evidence. The findings **complement the todo and the ledger's Goal** (update both), then the human picks a mode and execution continues. No implementation code is written in this mode. | codebase reality |
| 3. **Autonomous TDD** | Execute the todo end-to-end through the phase loop below with TDD integrated (validate test behavior via `clarify` before production code, red → green → refactor). | `## Phases` DAG |

Suggested default: **mode 3** for a complete level-3 todo with a verified
DAG; **mode 2** when the shaping found discrepancies with the repo; **mode 1**
when the todo's `## Verification` is precise and the human wants the contract
pinned before implementation. The agent may suggest — the human decides.

```json
{
  "question": "How do we start the implementation?",
  "choices": [
    "Autonomous execution with TDD (suggested)",
    "Test-first: write the failing test from Verification + Goal",
    "Research the codebase first",
    "Stop — information is missing"
  ]
}
```

Mode 1: after the validated failing test, enter the phase loop. Mode 2: the
findings complement the todo (via `dran-todo-flow`, only what the codebase
evidence supports) and the ledger's `Goal`/context (via `riel-ledger`) — then
the human picks a mode and execution continues from there.

## How to read `## Phases` (level 3) — mandatory

The DAG in `## Phases` is the **specification**, not an illustration. Each
phase carries:

| Phase field | What it is | Used in |
|---|---|---|
| `**Scope**` | files it can touch (1 or several) | validating diff ⊆ scope |
| `**Context (what exists now)**` | current state of the code | subagent brief |
| `**What changes**` (+ algorithm) | the logic to implement | subagent brief |
| `**Instruction DAG**` | steps with verbs | subagent brief |

1. **Nodes = phases.** Each node is a dispatchable unit of work.
2. **Incoming arrows** = phases that must be `done` before starting.
3. **Phases without dependencies** → dispatchable in **parallel** IF they
   touch different files; if they share a file → **serialize**.
4. The **algorithm** (mermaid in `What changes`) describes the logic; the
   **instruction DAG** describes the editing steps. They are not the same.

## Verb vocabulary → tools

Execution nodes use **only these 6 verbs** — semantic actions, not tool names:

| Verb | Meaning | Tool | Example |
|-------|-------------|------|---------|
| `READ path:line` | Read file/section | `read_file` | `read_file(path, offset, limit)` |
| `EDIT path — x` | Modify file | `patch` | `patch(path, old_string, new_string)` |
| `CREATE path — x` | New file | `write_file` | `write_file(path, content)` |
| `RUN cmd` | Run command | `terminal` | `terminal(command=cmd)` |
| `VERIFY cond` | Gate check | `terminal` + assert | `git diff --name-only` vs scope |
| `ASK question` | Clarify with human | `clarify` | `clarify(question, choices)` |

**Rule:** if a node doesn't start with one of these 6 verbs, the todo is
malformed → do not execute; ask for a correction via `dran-todo-flow`.

## Local ledger (delegated to riel-ledger)

`dran-coder-flow` does not keep cross-phase state in its head — it delegates it to
the ledger. Load `riel-ledger` and follow its protocol:

The ledger is created in the Opening (before any shaping) from the todo's
info. From there:

1. **Re-read at every seam** (phase change, tool call, file, long gap).
2. **Append `✓NN`** with verifier + coverage when passing each gate.
3. **Recovery**: if the work degrades, go back to the last `✓NN` with a fresh
   plan.
4. **done-check** at the end: each line of the `## Goal` ↔ a `✓NN`.

Make sure `.riel/` is in the worktree's `.gitignore` before committing
anything.

## Subagent dispatch (via riel-delegate + riel-briefs)

Subagent dispatch uses the Riel delegation framework — `riel-delegate` for
the dispatch/verify pattern, `riel-briefs` for the packet format. Do NOT
build the brief inline — use `riel-briefs` to assemble a self-contained
packet with curated context, verb-graph, gates, and anchored opening.

### Mandatory context of each brief (via riel-briefs)

1. **Protocol opening** (`riel-protocol`): `goal` opens with the shared
   objective — "We need <phase objective>…" — short stable persona, minimal
   surface (only what the phase needs).
2. **Repo path** and working branch.
3. **Scope** of its phase — the ONLY files it can touch.
4. The phase's **Context (what exists now)** and **What changes**.
5. The phase's **instruction DAG** (verbs).
6. **Rules:** don't touch files outside the scope; commit per feature.
7. Response **language** (Spanish).

### Parent verifies returns (via riel-delegate)

The parent agent does NOT trust the subagent's self-report — it verifies
the return with confidence X/20 before accepting:
- Re-run the gate (`mix compile --warnings-as-errors` + `mix test <paths>`)
- `git diff --name-only` against the scope
- If the return claims "done" but the gate fails → re-dispatch with the
  error as context (riel-delegate recovery pattern)

### Parallel vs serial

| Situation | Decision |
|-----------|----------|
| Disjoint phases (different files, no dependency) | one subagent per phase, **in parallel** |
| Two phases touch the same file | **serialize** |
| Phases with a dependency in the DAG | **serialize** respecting the order |

⚠️ **Git race:** parallel subagents that commit compete for the git index.
Prevention: dispatch serially, or have the parent make the commits after
verifying each subagent's work. Recovery: `git reset --soft` and re-commit.

## Gates + confirmation before commit

**Verification ALWAYS precedes commit** — in every execution mode and every
phase, the order is fixed: implement → verify (gate) → confirm → commit. A
commit without a green gate does not exist; the clarify only happens after
the verify passed.

Each phase's gate runs **before** commit, never after:

- [ ] `mix compile --warnings-as-errors` passes
- [ ] Scope tests pass (`mix test <file(s)>`)
- [ ] **Smoke test** — boot/runtime that touches what changed (starts the
  server, mounts the route, exercises the path). Mandatory for code.
- [ ] `mix format --check-formatted` without extra diffs
- [ ] Diff reviewed: only scope files

**Confirm before commit** — never commit automatically. After the green gate,
present files + message and `clarify`:

```json
{
  "question": "Green gate. Shall I commit?",
  "choices": ["Commit", "Edit message", "Split commits", "Cancel"]
}
```

**Failed gate** → re-dispatch with the exact error as context. Never advance
with a red gate.

## Done-check and close

1. **done-check (riel-ledger):** each line of the `## Goal` ↔ a `✓NN` with
   coverage. Each `✓NN` must carry evidence a **human can verify by hand**
   (command output, UI behavior, log line). If missing → no done.
2. Unclosed `?NN` → report to Álvaro (they don't go into the body).
3. **push-close:** `dran_update_todo({ slug, kanban_status: "done" })` — the
   only safe path (meta merge).
4. Report to Álvaro: deliverable + evidence (tests, smoke, commits).
5. **Hand-off to review:** after the PR is created, the review lives in
   `dran-review-flow` — that skill reviews the PR against this todo's
   `## Verification` and gates.

## clarify rules

1. **Human decides, agent only suggests** — execution mode, commit approval,
   test behavior, and between-phase confirmations are the human's call. The
   agent presents options with a suggested default; it never proceeds on a
   choice the human did not make.
2. **One blocking question per turn** — ask only for the input that unblocks
   the most; never a questionnaire.
3. **No re-ask** — never ask for what was already given in the conversation
   or returned by a tool call.
4. **TDD with human validation** — before writing production code, validate
   the test behavior via `clarify` (what is tested, what is expected), then
   red → green → refactor.
5. **Don't modify tests without validation** — modify/delete/downgrade an
   existing test only if strictly necessary and after `clarify`.
6. **Confirm between phases** — if the mode is "one by one", `clarify`
   between phases: `['Next phase', 'Review diff', 'Modify plan', 'Stop']`. In
   "continuous run" mode, the technical gates suffice.

## Updating the todo during execution (Dran adapter)

```
1. Completed phase checkbox → dran_update_page with ONLY body
   (passing meta together with body would strip the todo's mermaid)
2. Status → dran_update_todo (meta merge) — the only safe path
3. done → dran_update_todo({ slug, kanban_status: "done" })
   ONLY with a green done-check
4. Report to Álvaro: deliverable + evidence (tests, smoke, commits)
```

## Pitfalls

- **Starting without protocol + ledger** — both open FIRST, from the todo's
  info (never from assumptions), and live for the whole flow.
- **Choosing the execution mode without asking** — the human decides; the
  agent only suggests (and marks its suggestion as such).
- **Improvising against the codebase** — the mermaid and the shaping are
  grounded in real evidence (`path:line`); if it doesn't match, `clarify`,
  don't invent.
- **Committing before verifying** — the gate (including smoke) runs BEFORE the
  commit, never after.
- **Accumulating `✓NN` in Dran** — the evidence lives in the local ledger;
  Dran only receives checkboxes + status.
- **Reimplementing the ledger** — delegate to `riel-ledger`, don't duplicate.
- **Parallelizing phases that overlap** — if they share a file, serialize.
- **Advancing with a red gate** — the next phase inherits the error.
- **`done` with warnings** — `--warnings-as-errors` is part of the gate.
- **Skipping the smoke test** — it's mandatory for code.
- **Committing `.riel/`** — make sure the worktree `.gitignore` first.
- **Touching files outside the scope** — the diff is reviewed against the
  `Scope`.
- **Oversized or unverifiable todo** — body max 6–8 KB and every verification
  criterion human-checkable; otherwise split/fix via `dran-todo-flow` before
  executing.

## Quick reference

| Tool | Minimal args | Returns |
|------|--------------|---------|
| `dran_get_page` | todo `slug` | Full body (phases + context) |
| `delegate_task` | `goal` + `context` (full brief) | Subagent result |
| `dran_update_page` | `slug`, `body` (ONLY body) | Checked checkboxes |
| `dran_update_todo` | `slug`, `kanban_status` | Updated status (merge) |
| `terminal` | `mix compile --warnings-as-errors` / `mix test <file>` / smoke | Gates |

## When NOT to use this skill

- **The todo is not code** → manual execution or `dran-todo-flow` (level 2 research)
- **You're going to WRITE the todo** → `dran-todo-flow`
- **You're going to REVIEW a PR** → `dran-review-flow`
- **You're going to define the high-level path** → `dran-planning-flow`
- **It's research, not implementation** → `dran-research-flow`

## Cross-references

- How the todo is written (levels 1/2/3): `dran-todo-flow`
- Review of PRs against a todo: `dran-review-flow`
- Anchored opening + trajectory maintenance: `riel-protocol`
- Local state (ledger ✓NN): `riel-ledger`
- mermaid and verb contract: `riel-contract`
- Subagent dispatch + verify pattern: `riel-delegate`
- Self-contained brief packets: `riel-briefs`
- Plan that groups the todos: `dran-planning-flow`
- Commit hygiene for subagents: `git-workflow`
- MCP reference: `dran` — main skill
