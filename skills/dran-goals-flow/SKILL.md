---
name: dran-goals-flow
description: "Use when creating, updating, or reviewing Dran goals."
version: 1.0.0
author: Álvaro Lizama
license: MIT
metadata:
  hermes:
    tags: [dran, mcp, goals, okr]
    related_skills: [dran, dran-knowledge-flow, dran-workflow-flow]
---

# dran-goals-flow — Create and manage goals

A goal is the objective page with a lifecycle (`draft → active → on_hold →
done → archived`). Goals are **human-managed OKRs**: the agent creates and
updates them on request, but the checklist is Álvaro's territory.

## Entry router

```mermaid
flowchart TD
  Q{What do you need?} -->|"goal: create, status,\nread, delete"| SELF["THIS SKILL\ndran-goals-flow"]
  Q -->|"execute the steps of\na goal (workflows)"| W[dran-workflow-flow]
  Q -->|"note/concept/project\npage"| K[dran-knowledge-flow]
  Q -->|"connection, auth"| D[dran — main]

  style SELF fill:#d1fae5,stroke:#059669
```

## Parse contract

CONSUMES: an objective to track (title, optional summary). PRODUCES: a goal
confirmed by `dran_get_goal` readback. **A write without readback is not
done.**

## Operational flow

```mermaid
flowchart TD
  START([goal task]) --> S1["RUN mcp_dran_dran_list_goals\nworkspace"]
  S1 --> G1{"goal exists?"}
  G1 -->|"no"| S2["RUN mcp_dran_dran_create_goal\nworkspace + title"]
  G1 -->|"yes"| S3["RUN mcp_dran_dran_update_goal\nstatus draft active on_hold\ndone archived"]
  S2 --> V1["VERIFY dran_get_goal\nreadback: title + status"]
  S3 --> V1
  V1 -->|"mismatch"| S1
  V1 -->|"holds"| G2{"delete\nrequested?"}
  G2 -->|"yes"| S4["ASK confirm delete -\nirreversible"]
  S4 --> S5["RUN mcp_dran_dran_delete_goal"]
  S5 --> END([done])
  G2 -->|"no"| END
```

## The checklist boundary (hard rule)

`dran_goal_checklist_add / _toggle / _remove` exist as **convenience for
Álvaro's own tooling, not as agent writeback**. Decisions:

- The checklist is the human OKR surface: only mark/toggle items when
  Álvaro explicitly asks for that operation.
- The agent's durable progress evidence lives in workflow **runs**
  (dran-workflow-flow) — a step whose run closed `passed` renders checked
  in the DAG; that is the machine-side ✓NN.
- Memory (dran-memory-flow) and goal checklists are **not** riel
  checkpoints; never route execution state into either.

## Notes on the calls

- `dran_create_goal` requires `workspace` + `title`; status enum: `draft`,
  `active`, `on_hold`, `done`, `archived`. Goals have no own `progress`
  field — rollup is computed from linked structure.
- `dran_get_goal` accepts slug or UUID; prefer slug when known.
- Workflows attach to goals (`goal_id`); to see the execution side, read
  `dran_list_workflows` / `dran_get_workflow` (dran-workflow-flow owns
  those).
- MCP surface for goals: `dran_create_goal`, `dran_get_goal`,
  `dran_update_goal`, `dran_delete_goal`, `dran_list_goals`, and the three
  checklist tools. Goals have no `parent_goal` write path over MCP.

## Pitfalls

- **Treating the checklist as the agent's todo list** — it isn't; ask-first
  or don't touch.
- **Re-creating a goal that exists with different title casing** —
  `list_goals` first; the board dislikes duplicates.
- **Marking `done` from MCP on execution hunch** — status transitions on
  request or with evidence (passed sessions), never vibes.

## Checklist

- [ ] list_goals checked before create (no duplicates)
- [ ] Write verified by get_goal readback
- [ ] Checklist untouched unless Álvaro asked
- [ ] delete went through ASK
