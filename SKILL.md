---
name: second-brain
description: "Use when operating Álvaro's personal second brain via the Dran MCP server. 18 tools for capturing, relating, querying and maintaining typed knowledge pages (notes, concepts, entities, references, goals, plans, projects, todos, queries) as a knowledge graph. Triggers on anything Dran / segundo cerebro / brain: thoughts, notes, research, URLs, goals, plans, projects, todos, or delegating longer tasks to agents."
version: 7.1.0
author: Álvaro Lizama
license: MIT
metadata:
  hermes:
    tags: [dran, second-brain, mcp, knowledge-graph, notes, productivity]
    related_skills: [obsidian, notion, apple-notes]
---

# second-brain — Dran MCP Skill

## 1. What is Dran

Dran is a **personal second-brain / knowledge-graph server**. Every piece of
knowledge is a typed **page** connected by typed **relations**, all operated
through a single MCP endpoint.

- **Pages** are the atoms. Each has a `page_type`, a markdown `body`, and a
  JSONB `meta` whose valid fields depend on the type.
- **Relations** are directed links. `semantic` relations are created
  automatically by the augmenter after every create/update; the rest
  (`related`, `part_of`, `supersedes`, `contradicts`, `embeds`) are explicit.
- **Search** fuses FTS + semantic via reciprocal-rank fusion with a PageRank
  authority boost — well-linked pages rank higher.
- **Contexts** partition the brain (e.g. `personal`, `work`). Pages, relations
  and search are always scoped to one context.

## 2. Connection

| Item | Value |
| --- | --- |
| Transport | Streamable HTTP, MCP spec **2025-03-26** |
| Endpoint | `POST http://<host>/api/mcp` |
| Auth | `Authorization: Bearer <token>` — per-user API token |
| Default context | **`personal`** — do not ask, do not switch unless Álvaro says so |

Auth is **per-user**: each user has one `api_token` for all their assigned
contexts. Requests return `401` for invalid tokens and `403` for contexts the
user isn't assigned to. The legacy `DRAN_API_TOKEN` env token is treated as
admin with access to all contexts.

## 3. Page types (9)

| Type | Use it for | Subtypes (`meta.kind`) |
| --- | --- | --- |
| `note` | Thoughts, journal, ideas, meetings, questions, quotes, reminders | thought, journal, idea, meeting, question, quote, reminder |
| `concept` | Techniques, patterns, disciplines, theories | technique, pattern, discipline, theory |
| `entity` | People, companies, products, tools, places, events | person, company, product, tool, place, event |
| `reference` | External sources | article, paper, video, podcast, book |
| `project` | Larger initiatives grouping goals/plans/todos | — |
| `goal` | Objectives with a measurable target | personal, coding, business, learning, health, finance, other |
| `plan` | Time-horizoned plans (weekly/monthly/quarterly/yearly) | personal, coding, business, learning, health, finance, other |
| `todo` | Actionable items with kanban status | personal, coding, business, learning, health, finance, other |
| `query` | Questions with answers | factual, conceptual, how_to, opinion |

Default to `note` with `meta.kind: "thought"` when unsure — promote later.

### Per-context page type disabling

Each context can **disable page types** (`disabled_page_types`). A disabled
type is hidden in the web UI and **rejected by the MCP API**: creating or
listing it returns an error (`page type 'X' is disabled in context 'Y'`).
Before creating a page of an unusual type in an unfamiliar context, expect the
possibility that it's disabled.

### Link model — independent slugs

Any page may carry any combination of `meta.project_slug`, `meta.goal_slug`
and `meta.plan_slug` — **0, 1, 2, or all 3**. Each one materializes its own
`part_of` relation automatically. No precedence, no derivation. Orphans (no
links) are legitimate GTD-style inbox items. In `dran_list_pages`, the value
`"none"` filters pages without that link.

## 4. Tools (18)

Grouped by workflow: capture → read/find → organize → maintain → automate.

### Capture

| Tool | Purpose |
| --- | --- |
| `dran_create_page` | Create any page type **except todos** |
| `dran_create_todo` | Create a todo with kanban status, priority, due date, and independent project/goal/plan links |

### Read & find

| Tool | Purpose |
| --- | --- |
| `dran_search` | **Use FIRST** — unified FTS/fuzzy/semantic/hybrid search, PageRank-boosted. Supports `limit`, `offset`, `type` filter |
| `dran_get_page` | Full markdown body of one page — always read before answering |
| `dran_list_pages` | Filtered list (type, tag, status, owner, assignee, project/goal/plan slug, `"none"` for orphans) |
| `dran_get_links` | Inbound + outbound relations for a page |

### Organize

| Tool | Purpose |
| --- | --- |
| `dran_update_page` | Update title/body/tags/meta — **replaces `meta` entirely**. ⚠️ When updating a page with mermaid diagrams, pass only `body` (no `meta`) or TipTap re-parses and strips the mermaid blocks |
| `dran_update_todo` | Update todo status/priority/date/links — **merges `meta`** (the only safe way to change todo status) |
| `dran_rename_slug` | Rename a slug; rewrites all `![[old-slug]]` embeds in the context |
| `dran_create_relation` | Explicit typed relation: `related`, `part_of`, `supersedes`, `contradicts`, `embeds`. **Never `semantic`** (automatic) |
| `dran_delete_relation` | Delete relations between two pages |
| `dran_delete_page` | Delete a page — **irreversible**, confirm with Álvaro first |

### Maintain

| Tool | Purpose |
| --- | --- |
| `dran_get_stats` | Totals, pages by type, todos by status, orphans, relations |
| `dran_lint_brain` | Orphans, stale pages (>90d), contested knowledge. Surface results — don't auto-fix |
| `dran_reaugment_page` | Re-run augmentation (summary/tags/embedding/relations) for a page |
| `dran_generate_community_summaries` | Generate LLM summaries for all detected graph communities |

### Automate

| Tool | Purpose |
| --- | --- |
| `dran_start_agent` | Launch an autonomous agent (`curator`, `link_gardener`, `graph_rag`) |
| `dran_get_agent_session` | Poll an agent session for status, steps, summary |

## 5. Resources & prompts

Resources (read-only, prefer over looping `dran_list_pages`):
- `page://{context}/{slug}` — full page markdown
- `goal://{context}/{slug}` — goal + linked todos/plans as JSON
- `wiki://{context}/index` — full context index in one call

Prompts: `brainstorm` (generate interlinked idea pages), `goal_review`
(review a goal with its todos/plans).

## 6. Autonomous agents (3)

| Agent | Purpose | Limits |
| --- | --- | --- |
| `curator` | Finds near-duplicate pages (embedding distance < 0.05), flags contested knowledge, writes a report note. Runs daily at 06:00 via Quantum | max 20 flags/session |
| `link_gardener` | Proposes typed relations for orphaned/under-linked pages, including verified transitive `part_of` candidates (A→C via B) | max 10 proposals/session |
| `graph_rag` | Answers questions using GraphRAG patterns — local search (fan-out to neighbors), global search (community summaries), or drift search (hybrid). Creates query pages with cited sources | 10 searches, 5 expands, 3 community contexts, 1 query page/session |

Lifecycle: `dran_start_agent` returns a `session_id` immediately → poll
`dran_get_agent_session` until `completed`/`failed`. Sessions persist every
step and track `meta.tokens_used` + `meta.model`.

## 7. Working rules

1. **Default context `personal`.** Don't ask, don't switch.
2. **Search before create.** 2-3 `dran_search` variants before every create.
   If it exists, update it.
3. **Read before answer.** Never answer from search excerpts — `dran_get_page`
   the top 2-3 results first.
4. **Edit > duplicate.** Updating beats creating a near-copy.
5. **Right `page_type` + `meta.kind`.** Action item → `todo` via
   `dran_create_todo`. External source → `reference`. Named thing in the world
   → `entity`. Abstract knowledge/technique → `concept`. Loose thought → `note`.
6. **Ownership defaults:** `owner: "alvaro"`, `created_by: "agent"` on
   everything you create. For todos, ALWAYS `clarify` the `assignee`
   (`alvaro` / `agent` / other) before creating.
7. **Ask when risky, infer when obvious.** Ask before deleting, renaming, or
   when goal/plan/project required fields (metric, horizon, priority) aren't
   inferable.
8. **Never create `semantic` relations manually.** They're automatic.
9. **Link liberally.** `part_of`/`related`/`embeds` boost PageRank → better
   search recall.
10. **Archive over delete.** Pages have an `archived` flag (set via
    `dran_update_page` with `archived: true`) — hidden from lists/search but
    recoverable. Delete only true junk, after confirmation.
11. **Todos without links are fine.** They land in the global kanban inbox —
    don't force links.
12. **`[[slug]]` wikilinks don't exist.** Use `![[slug]]` for embeds,
    `dran_create_relation` for typed links.

## 8. Status workflows

- **todo** — create in `backlog`, move to `in_progress` immediately with
  `dran_update_todo`, `done` only after verifying + committing. One
  `in_progress` at a time.
- **project** — create `draft`; auto-`active` when linked to a plan/todo/goal;
  `done`/`on_hold`/`archived` manual.
- **plan** — create `draft`; auto-`active` when a task executes; auto-`done`
  when ALL linked todos are done/cancelled; `archived` manual.
- **goal** — fully manual (`health`, `progress` only when Álvaro asks).
- **goal.progress** — auto-calculated from linked todos unless
  `progress_manual: true`.
- **project.health** — derived from linked goals unless
  `health_source: "manual"`.

## 9. Recipes

### Capture a thought

```
1. dran_search({ context: "personal", query: "<keywords>" })   → exists? update instead
2. dran_create_page({
     context: "personal",
     page_type: "note",
     body: "Today I learned...",
     meta: { kind: "thought" },
     tags: ["elixir"],
     owner: "alvaro",
     created_by: "agent"
   })
```

### Add a todo

```
1. clarify assignee → alvaro or agent
2. dran_create_todo({
     context: "personal",
     title: "Refactor MCP controller",
     project_slug: "<project>",   → optional, independent
     goal_slug: "<goal>",         → optional, independent
     plan_slug: "<plan>",         → optional, independent
     kanban_status: "backlog",
     priority: "high",
     assignee: "alvaro"
   })
3. dran_update_todo({ slug: "<slug>", kanban_status: "in_progress" })   → auto-move
```

### Plan a project

```
1. dran_create_page({ page_type: "project", title: "...", meta: { status: "draft", priority: "high" } })
2. dran_create_page({ page_type: "goal", title: "...", meta: { kind: "business", metric: "...", target_value: N } })
3. dran_create_page({ page_type: "plan", meta: { horizon: "quarterly", period: "2026-Q3", project_slug: "...", goal_slug: "..." } })
4. dran_create_todo({ ..., project_slug: "...", goal_slug: "...", plan_slug: "..." })   → set whichever subset applies
```

### Brain hygiene

```
1. dran_lint_brain({ context: "personal" })   → surface orphans/stale to Álvaro, don't auto-fix
2. dran_start_agent({ agent_type: "link_gardener", context: "personal", input: "orphaned pages" })
3. dran_get_agent_session({ session_id: "..." })   → poll until completed
```

## 10. Common mistakes

- **Creating without searching** — always search 2-3 variants first.
- **`dran_create_page` for todos** — use `dran_create_todo`.
- **`dran_update_page` for todo status** — use `dran_update_todo` (merges meta).
- **`meta` + `body` together on pages with mermaid** — strips the diagrams;
  pass only `body`.
- **Manually creating `semantic` relations** — automatic only.
- **Assuming link precedence** — project/goal/plan slugs are independent.
- **Passing `status` for `query` pages** — the field is `answer_status`.
- **Forgetting `progress_manual: true`** on goals not measured by todos.
- **Deleting without confirmation** — irreversible; prefer archive.
- **Answering from search excerpts** — read the page first.
