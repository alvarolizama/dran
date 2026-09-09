---
name: dran-create-workflow
description: "Use when authoring a Dran workflow from a plan — steps, contracts, context, DAG."
version: 1.0.0
author: Álvaro Lizama
license: MIT
metadata:
  hermes:
    tags: [dran, workflows, authoring, contracts, riel]
    related_skills: [dran, dran-workflow-flow, riel-contract, dran-knowledge-flow]
---

# dran-create-workflow — Turn a plan into a workflow DAG

Authoring layer: takes a plan (prose, checklist, mermaid, existing doc)
and produces a Dran workflow — definition only. Execution is
dran-workflow-flow; this skill never opens sessions.

Surface fact: **workflow authoring IS on MCP** — `dran_create_workflow`
creates the workflow with FULL step contracts inline (claims, gates,
graph, context, depends_on), and `dran_delete_workflow` deletes a draft
(both write-gated in `@write_tools`). The Dran UI step modal remains the
way to EDIT an existing contract; creation is one MCP call. This skill
authors the packet, materializes it via MCP, and verifies via
`dran_get_workflow` readback.

## Entry router

```mermaid
flowchart TD
  Q{What do you need?} -->|"new workflow from\na plan: steps + contracts"| SELF["THIS SKILL\ndran-create-workflow"]
  Q -->|"execute: session,\nruns, riel loop"| W[dran-workflow-flow]
  Q -->|"verb vocabulary /\ncontract conventions"| R[riel-contract]
  Q -->|"find pages to pin\nas context"| K[dran-knowledge-flow]

  style SELF fill:#d1fae5,stroke:#059669
```

Run ONLY the flow you landed on. If the diagram sends you to another
skill, **stop here** and hand off.

## Parse contract

CONSUMES: a plan in any shape, a workspace slug, an optional goal slug
to link (`goal_id`). PRODUCES: **a workflow packet** — every step with
its full contract, the `depends_on` DAG, and the kind — confirmed in
Dran by a `dran_get_workflow` readback. **A step without claims and
gates is not a step, it is a title.**

## The packet schema (per step)

| Field | Shape | Rules |
| --- | --- | --- |
| `title` | string ≤ 500 | imperative, one deliverable |
| `intent` | one sentence | opens the brief as "We need <intent>" |
| `claims` | `id` (P1, P2…), `claim`, `verify` | pre-registered; a failed claim is refuted, never reinterpreted |
| `gates` | `name`, `check`, `expect`, `on_failure` | `check` is the done-criterion — OPEN: a runnable command, an expected output artifact (a rendered video, a report), or an inspection of the result (frame analysis). The gate decides; the check only probes |
| `graph` | nodes `id`/`verb`/`label`, edges `from`/`to` | verbs from the closed set `READ EDIT CREATE RUN VERIFY ASK` (same as riel-contract) |
| `context` | entries `type` (`page`\|`memory`), `id`, `why` | pin only what the step needs; every entry carries its why |

Workflow-level: `kind` — `evergreen` (default; re-runnable, N sessions)
or `one_shot`; **kind CHANGES are locked once the workflow has any
session** (`{:error, :kind_locked}`; same-kind writes pass). Status
starts `draft`; activation is an explicit human decision, never yours.

## Operational flow

```mermaid
flowchart TD
  START([plan + workspace]) --> S1["READ the plan - decompose into\nverifiable steps"]
  S1 --> G1{"each step can close\npassed failed on its own?"}
  G1 -->|"no - merge or split"| S1
  G1 -->|yes| S2["EDIT author the packet - intent,\nclaims P-ids, gates, graph, context"]
  S2 --> G2{"every gate check is\nverifiable as written?"}
  G2 -->|no| S2
  G2 -->|yes| S3["EDIT the DAG - depends_on edges,\ncycle-free, minimal"]
  S3 --> G3{"cycle-free and\nno redundant edges?"}
  G3 -->|no| S3
  G3 -->|yes| S4["ASK kind evergreen or one_shot\n+ confirm packet with human"]
  S4 --> S5["CREATE via MCP dran_create_workflow\nfull contracts inline"]
  S5 --> S6["VERIFY dran_get_workflow\nsteps + depends_on + contract ✓"]
  S6 -->|"mismatch"| S5
  S6 -->|holds| END([workflow draft ready])
```

## Rules of authoring

- **Decomposition heuristic:** a step = one deliverable that can close
  `passed`/`failed` on its own gates. Two steps sharing all their gates
  are one step; a step that needs "and then" is two.
- **Gates are the verification funnel:** at least one gate per step, and
  the last gate must verify the step's claims. "Review the code" is not
  a gate; `mix test test/path/` with `expect: exit 0` is — but so is
  "video renderizado en outputs/" with `expect: archivo existe`, or a
  frame-analysis check. `check` is free text the pulling agent
  interprets.
- **Claims before work:** the P-ids written here are what the executor's
  run is audited against (dran-workflow-flow). Do not soften them to
  make them easier to pass.
- **Context triage:** pin pages/memories with the exact slug/id + why.
  An entry without a why is noise for the pulling agent; the brief's
  `## Context` renders one-liners and the fetch command per entry.
- **UI materialization facts:** creation is one `dran_create_workflow`
call with the whole packet; the UI (`/:workspace/workflows`) edits
existing contracts (step modal) and visualizes the canvas — edges render
as `dependent → prereq`. Steps append at `position` max+100.
- **depends_on resolution:** references previously declared steps by
TITLE or slug (the MCP executor resolves both); declare steps in DAG
topological order in the `steps` array.
- **Never activate or open a session here.** Hand off to
dran-workflow-flow when the human wants to run the plan.
`dran_delete_workflow` removes a mis-created draft (ASK the human first
— irreversible; refused when the workflow has sessions).

## Pitfalls

- **Looking for `dran_create_workflow` on MCP or REST** — it exists (37
tools as of this skill version); verify with `tools/list` if in doubt —
the surface grows.
- **Steps created bare (title/intent only)** — `dran_get_workflow` will
read `no contract`; the MCP payload must carry claims/gates/graph inline.
- **Gates that are not verifiable** — a gate whose `check` cannot be
  probed (run the command, inspect the output, check the artifact
  exists) cannot close a run honestly. Prefer a command when one
  exists; an artifact or inspection check is equally valid.
- **Flipping `kind` after the first session** — `{:error, :kind_locked}`;
  choose evergreen unless the plan is one-pass by nature.
- **Redundant diamond edges** — cycle-safety is enforced server-side
  (`Dran.Contracts`), but a redundant edge still serializes steps that
  could run in parallel.
- **Skipping the readback** — a UI paste is a write like any other;
  `dran_get_workflow` is the done-check.

## Checklist

- [ ] Every step: intent + at least one claim + one gate with a verifiable check
- [ ] Graph verbs inside the closed 6-verb set
- [ ] Context entries: type + exact id + why
- [ ] DAG cycle-free; kind chosen and confirmed with the human (ASK)
- [ ] Materialized in the UI; verified by `dran_get_workflow` readback
- [ ] Execution handed off to dran-workflow-flow (never run from here)
