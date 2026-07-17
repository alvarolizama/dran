---
name: second-brain
description: "Use when operating Álvaro's personal second brain via the Dran MCP server. 18 tools for capturing, relating, querying and maintaining typed knowledge pages (notes, concepts, entities, references, goals, plans, todos, artifacts, comparisons, queries) as a knowledge graph. Triggers on anything Dran / segundo cerebro / brain: thoughts, notes, research, URLs, goals, todos, comparisons, weekly reviews, or delegating longer tasks to agents."
version: 5.0.0
author: Álvaro Lizama
license: MIT
metadata:
  hermes:
    tags: [dran, second-brain, mcp, knowledge-graph, notes, productivity]
    related_skills: [obsidian, notion, apple-notes]
---

# second-brain — Dran MCP Skill

## 1. Overview

Dran is a **personal second-brain / knowledge-graph server**. Every piece of
knowledge is a typed **page** (note, concept, entity, reference, goal, plan,
todo, artifact, comparison, query) connected by typed **relations**
(`semantic`, `related`, `part_of`, `supersedes`, `contradicts`, `embeds`). All
operations go through a single MCP endpoint — there is no need to use the REST
API or web UI for agent-driven workflows.

**Tech stack:** Phoenix LiveView + PostgreSQL with `pgvector` + Bandit, OpenAI-compatible inference API for embeddings/rerank/chat/vision/ASR.

- **Pages** are the atoms of the graph. Each page has a `page_type`, a markdown
  `body`, and a JSONB `meta` whose valid fields depend on the type.
- **Relations** are directed links between pages. `semantic` relations are
  created automatically by `PageAugmenter` after every create/update; the rest
  are created explicitly with `dran_create_relation`.
- **Embeddings** are generated for every page and stored in `pgvector`. After
  `dran_create_page` / `dran_update_page`, the augmenter asynchronously creates
  `semantic` relations to the closest neighbours and extracts title/summary/tags.

---

## 2. Connection

| Item | Value |
| --- | --- |
| Transport | Streamable HTTP, MCP spec **2025-03-26** |
| Endpoint | `POST http://<host>/api/mcp` |
| Auth | `Authorization: Bearer <DRAN_API_TOKEN>` |
| Default context | **`personal`** — do not ask, do not switch unless Álvaro says otherwise |
| Hermes config | `~/.hermes/config.yaml` → `mcp_servers.dran` |

**Hermes config snippet (`~/.hermes/config.yaml`):**

```yaml
mcp_servers:
  dran:
    url: http://localhost:4000/api/mcp
    headers:
      Authorization: "Bearer dran-token"
```

**Notes:**

- The server returns an `mcp-session-id` header on `initialize`. Include it in
  subsequent requests of the same session.
- Requests with an `id` field receive a JSON response. Notifications (`method`
  with no `id`) return `202` with an empty body.
- If the endpoint returns `401`, check the `DRAN_API_TOKEN` / Bearer value
  before assuming Dran is down.

---

## 3. Tools (18)

Tools are grouped by **workflow pipeline**, not alphabetically. Follow the
groups in order: capture → read/find → organize → maintain → automate.

### Capture

| Tool | Purpose | Use when / don't use when |
| --- | --- | --- |
| `dran_create_page` | Create any page type. | Use for notes, concepts, entities, references, goals, plans, artifacts, comparisons, queries. **Don't use for todos** — use `dran_create_todo`. |
| `dran_create_todo` | Create a todo with kanban status, priority, due date, plan/goal linkage. | Use for action items. Optional `plan_slug` links to a plan (goal derived); `goal_slug` links directly. **Don't use `dran_create_page` with `page_type=todo`** — it won't get the right meta shape. |
| `dran_ingest_url` | Save a URL as a `reference` page, or download a file. With inference enabled, extracts content (MarkItDown/Vision/ASR). | Use for web articles and file URLs. **Don't pass local/private IPs** — SSRF protection blocks them. |

### Read & find

| Tool | Purpose | Use when / don't use when |
| --- | --- | --- |
| `dran_search` | Unified search: auto picks FTS, fuzzy, semantic, or hybrid. | **Use FIRST** whenever you're looking for something — before `dran_create_page`, before answering a question. Use the `type` filter when you can. |
| `dran_get_page` | Full markdown body of one page. | Use to actually **read** a page after finding it via `dran_search` / `dran_list_pages`. **Don't call without searching first** unless Álvaro gave you the exact slug. |
| `dran_list_pages` | Filtered lightweight list (type, tag, status, goal_slug, plan_slug, limit). | Use for filtered overviews and planning-hierarchy exploration — `goal_slug`/`plan_slug` filter by goal/plan; pass `'none'` for orphans (plans without a goal, todos without a plan). **Don't loop it to build an index** — use the `wiki://{context}/index` resource instead. |
| `dran_get_links` | Inbound + outbound relations for a page. | Use to inspect the graph around a page before relating or deleting. |

### Organize

| Tool | Purpose | Use when / don't use when |
| --- | --- | --- |
| `dran_update_page` | Update title/body/tags/meta. **Replaces** `meta` entirely. | Use for content edits. **Don't use for todo status** — `dran_update_todo` merges meta; `dran_update_page` replaces it. |
| `dran_update_todo` | Update todo status/priority/date. **Merges** `meta`. | Use for any todo status/priority change. This is the only safe way to change todo status. |
| `dran_rename_slug` | Rename a page slug. Rewrites `![[old-slug]]` embeds across the context. | Use when a slug is wrong. **Don't use lightly** — all embeds are rewritten. |
| `dran_create_relation` | Create an explicit typed relation between pages. | Use for `related`, `part_of`, `supersedes`, `contradicts`, `embeds`. **Never create `semantic` manually** — they are automatic. |
| `dran_delete_relation` | Delete relations between two pages (optionally by type). | Use to clean up wrong links. |
| `dran_delete_page` | Delete a page. **Irreversible**, cascades to relations + versions. | Use only after confirming with Álvaro. **Don't use without confirmation.** |

### Maintain

| Tool | Purpose | Use when / don't use when |
| --- | --- | --- |
| `dran_get_stats` | Dashboard: totals, pages by type, todos by status, orphans, relations. | Use for context overviews, weekly reviews, dashboards. |
| `dran_lint_brain` | Orphans, stale pages (>90d), contested knowledge. | Use after batches of changes. Surface results to Álvaro — **don't auto-fix**. |
| `dran_reaugment_page` | Re-run the augmentation pipeline (summary/tags/embedding/relations) for a page. | Use when augmentation failed or content changed significantly. |

### Automate

| Tool | Purpose | Use when / don't use when |
| --- | --- | --- |
| `dran_start_agent` | Launch an autonomous agent (6 types — see §6). | Use for multi-step research, ingest, Q&A, or maintenance. **Don't use for simple dran_search** — use `dran_search` directly. |
| `dran_get_agent_session` | Poll an autonomous agent's progress and results. | Use to check status of a running agent session. |

---

## 4. Resources (read-only)

Prefer these over looping `dran_list_pages` when you need an overview:

| URI | Returns | Prefer over |
| --- | --- | --- |
| `page://{context}/{slug}` | Full page markdown | — |
| `goal://{context}/{slug}` | Goal + linked todos/plans as JSON | Manual join of goal + todos |
| `wiki://{context}/index` | Full index of the context (slug + title + type) | Loop of `dran_list_pages` calls |

---

## 5. Prompts

| Prompt | Use |
| --- | --- |
| `research_topic` | Scaffold a research page (outline, sources, questions). |
| `brainstorm` | Generate 5-10 interlinked idea pages. |
| `goal_review` | Review a goal, its todos and plans, suggest next actions. |

---

## 6. Autonomous agents

For multi-step research, ingest, Q&A, or maintenance tasks, delegate with
`dran_start_agent` and poll with `dran_get_agent_session`:

| Agent | Purpose | Key limits |
| --- | --- | --- |
| `research` | Searches/scrapes the web and creates `note`/`reference` pages. | max 10 sources, max 10 pages, max 10 dran_search queries (configurable via Settings). |
| `ingest` | Validates, inspects, downloads a URL and creates a `reference` page. | File download limit 100 MiB. |
| `ask` | Answers a question using **only** knowledge already in the brain; persists the answer as a `query` page. | max 5 dran_search queries; one query page per session. |
| `curator` | Reviews pairs of pages with very similar embeddings, flags duplicates/contested content, writes a report note. | max 20 flags per session; duplicate threshold 0.05. |
| `link_gardener` | Reads orphaned/under-linked pages, proposes typed relations with justifications. | max 10 proposals per session; `semantic` type forbidden. |
| `weekly_review` | Gathers brain dran_stats and writes a weekly review journal page. | Window: pages created in last 7 days. Output in **Spanish**. |

**Lifecycle:** `dran_start_agent` returns a `session_id` immediately. Poll
`dran_get_agent_session` with that `session_id` until `status` reaches a terminal
state (`completed` / `failed`). Failed sessions (crashes, timeouts, max
consecutive errors) are marked `failed` with a summary explaining the cause.
Each session tracks `meta.tokens_used` (accumulated LLM token usage) and
`meta.model` for cost/usage tracking.

```json
{
  "agent_type": "research",
  "context": "personal",
  "input": "Yeshe Walmo"
}
```

There is no dedicated dran_search agent; for dran_search-only tasks use `dran_search` directly.

---

## 7. Working rules

1. **Default context is `personal`.** Do not ask. Do not switch unless Álvaro
   says otherwise.
2. **Search before create.** Run 2-3 related `dran_search` queries before every
   `dran_create_page`. If a relevant page exists, update it instead.
3. **Read before answer.** When Álvaro asks "what do I know about X?", `dran_search`,
   then `dran_get_page` the top 2-3 results. Do not answer from dran_search excerpts.
4. **Infer when obvious, ask when risky.** Infer page type, slug and tags from
   context. Ask before deleting, renaming, or touching identity/finances.
5. **Edit > duplicate.** Updating an existing page is almost always better than
   creating a new one.
6. **Use `dran_search` first, `dran_list_pages` only for filtered lists.** Never loop
   `dran_list_pages` to build an index — use the `wiki://personal/index` resource.
7. **Use `dran_get_page` to read.** Never answer from dran_search excerpts alone.
8. **Never create `semantic` relations manually.** They are automatic.
9. **Plain `[[slug]]` wikilinks are not supported.** Use `![[slug]]` only to
   embed artifacts (auto-creates `embeds` relations); use `dran_create_relation`
   for explicit typed relationships.
10. **Surface dran_lint results, don't auto-fix.** Run `dran_lint_brain` after batches of
    changes and show orphans/stale pages to Álvaro.
11. **Always confirm with Álvaro before deleting.** `dran_delete_page` is
    irreversible.

---

## 8. Page types

| Type | Use it for | Subtypes (`meta.kind`) | Key `meta` fields |
| --- | --- | --- | --- |
| `note` | Thoughts, journal, ideas, meetings, questions, quotes | thought, journal, idea, meeting, question, quote | kind, date, author, attendees, resolved, source_ref |
| `concept` | Techniques, patterns, disciplines, theories | technique, pattern, discipline, theory | kind, domain, parent_concept |
| `entity` | People, companies, products, tools, places, events | person, company, product, tool, place, event | kind, aliases, external_url, location |
| `reference` | External sources | article, paper, video, podcast, book | kind, source_url, published_at |
| `artifact` | Files, code snippets, designs, deliverables | document, code, design, deliverable, file | kind, filename, mime_type, storage_path, sha256 |
| `goal` | Objectives with target date | — | health (green/yellow/red), start_date, target_date, team |
| `plan` | Time-horizoned plans | — | horizon, status, period, goal_slug |
| `todo` | Actionable items | — | kanban_status, priority, due_date, goal_slug, plan_slug, assignee |
| `comparison` | Side-by-side analyses | — | entities, criteria, verdict |
| `query` | Questions with answers | factual, conceptual, how_to, opinion | kind, difficulty, answer_status, answered_by |

Default to `note` when unsure. Promote later with `dran_update_page`.

### Planning hierarchy

```
goal ◄── plan ◄── todo
         meta.goal_slug   meta.plan_slug (goal derived from plan)
```

- A **todo** can exist with no plan and no goal (inbox todo), under a plan
  (`plan_slug`), or linked directly to a goal (`goal_slug`).
- A **plan** can exist without a goal (orphan plan) or link to one via
  `meta.goal_slug`.
- When a todo has `plan_slug`, its goal is **derived from the plan** — do not
  also set `goal_slug` (it can contradict the plan's goal).
- `part_of` relations (todo→plan, plan→goal, todo→goal direct) are
  **auto-materialized** when the slugs are set; you do not create them
  manually with `dran_create_relation`.
- Use `dran_list_pages` with `goal_slug="none"` or `plan_slug="none"` to find
  orphans (plans without a goal, todos without a plan).

### Meta validation reference (condensed)

| `page_type` | Field | Valid values |
| --- | --- | --- |
| `note` | `kind` | thought, journal, idea, meeting, question, quote |
| `concept` | `kind` | technique, pattern, discipline, theory |
| `entity` | `kind` | person, company, product, tool, place, event |
| `reference` | `kind` | article, paper, video, podcast, book |
| `artifact` | `kind` | document, code, design, deliverable, file |
| `todo` | `kanban_status` | backlog, this_week, today, in_progress, done, cancelled |
| `todo` | `priority` | low, medium, high, urgent |
| `goal` | `health` | green, yellow, red |
| `plan` | `horizon` | weekly, monthly, quarterly, yearly |
| `plan` | `status` | draft, active, on_hold, completed, archived |
| `query` | `kind` | factual, conceptual, how_to, opinion |
| `query` | `difficulty` | simple, intermediate, advanced |
| `query` | `answer_status` | open, answered, verified |

`title` and `slug` are optional on `dran_create_page`: if omitted, Dran derives them
from the first non-empty line of `body`.

After `dran_create_page` / `dran_update_page`, Dran automatically: (1) extracts/refines
title, summary, tags and inline links via inference; (2) generates and stores
an embedding; (3) creates `semantic` relations to similar pages; (4) resolves
`![[slug]]` embeds into `embeds` relations (and cleans stale ones on update).

---

## 9. Recipes

### Capture a thought

```
1. dran_search({ context: "personal", query: "<keywords>" })   → check for existing page
2. dran_create_page({
     context: "personal",
     page_type: "note",
     body: "Today I learned that Elixir's `=` is a match operator, not an assignment.",
     meta: { kind: "thought" },
     tags: ["elixir", "programming"]
   })
```

### Capture meeting notes

```
1. dran_search({ context: "personal", query: "<meeting topic>" })   → check for existing page
2. dran_create_page({
     context: "personal",
     page_type: "note",
     body: "## Meeting notes\n- Topic: ...\n- Decisions: ...",
     meta: { kind: "meeting", date: "2026-07-17", attendees: ["Álvaro", "Paty"] }
   })
3. dran_create_relation({ source_slug: "<meeting-slug>", target_slug: "<person-entity>", relation_type: "related", context: "personal" })
   → repeat for each attendee entity
```

### Process a research article

```
1. dran_ingest_url({ url: "https://example.com/article", context: "personal", tags: ["research"] })
   → creates a `reference` page
2. dran_get_page({ context: "personal", slug: "<reference-slug>" })
   → read the extracted content
3. dran_create_page({ context: "personal", page_type: "note", body: "## Summary\n...", meta: { kind: "idea" } })
   → capture your takeaways
4. dran_create_relation({ source_slug: "<note-slug>", target_slug: "<reference-slug>", relation_type: "part_of", context: "personal" })
5. If augmentation failed (no semantic links appeared): dran_reaugment_page({ context: "personal", slug: "<reference-slug>" })
```

### Research a topic (delegated to agent)

```
1. dran_start_agent({ agent_type: "research", context: "personal", input: "Yeshe Walmo" })
   → returns { session_id: "..." }
2. dran_get_agent_session({ session_id: "..." })   → poll until status: "completed"
3. dran_get_page({ context: "personal", slug: "<created-page-slug>" })
   → read each created note/reference page
4. dran_create_relation({ source_slug: "<new-slug>", target_slug: "<existing-slug>", relation_type: "related", context: "personal" })
   → link to existing knowledge if the agent didn't
```

### Add a todo to a goal

```
1. dran_search({ context: "personal", query: "<goal name>", type: "goal" })
   → find the goal slug
2. dran_create_todo({
     context: "personal",
     title: "Refactor MCP controller",
     slug: "refactor-mcp-controller",
     goal_slug: "<goal-slug>",
     kanban_status: "this_week",
     priority: "high",
     due_date: "2026-07-20"
   })
```

### Mark a todo done

```
1. dran_update_todo({ context: "personal", slug: "refactor-mcp-controller", kanban_status: "done" })
```

Use `dran_update_todo`, not `dran_update_page` — `dran_update_todo` merges meta safely.

### Weekly review (delegated to agent)

```
1. dran_start_agent({ agent_type: "weekly_review", context: "personal", input: "weekly review" })
   → returns { session_id: "..." }
2. dran_get_agent_session({ session_id: "..." })   → poll until status: "completed"
3. dran_get_page({ context: "personal", slug: "<review-page-slug>" })
   → read the generated review (output is in Spanish)
```

### Create a comparison

```
1. dran_search({ context: "personal", query: "Phoenix framework" })   → find existing entity pages
2. dran_search({ context: "personal", query: "Rails framework" })
3. dran_create_page({
     context: "personal",
     page_type: "comparison",
     title: "Phoenix vs Rails",
     body: "## Phoenix vs Rails\n![[phoenix]]\n![[rails]]\n...",
     meta: {
       entities: ["phoenix", "rails"],
       criteria: ["performance", "concurrency", "ecosystem"],
       verdict: "Phoenix for real-time; Rails for CRUD speed."
     }
   })
   → embeds `![[phoenix]]` and `![[rails]]` auto-create `embeds` relations
```

### Plan a goal

```
1. dran_search({ context: "personal", query: "<goal name>", type: "goal" })
   → confirm the goal doesn't already exist
2. dran_create_page({
     context: "personal",
     page_type: "goal",
     title: "Ship Dran v2",
     body: "## Ship Dran v2\n...",
     meta: { health: "green", start_date: "2026-07-01", target_date: "2026-10-31", team: ["alvaro"] }
   })
3. dran_create_page({
     context: "personal",
     page_type: "plan",
     title: "Q3 2026 plan — Ship Dran v2",
     body: "## Q3 plan\n...",
     meta: { horizon: "quarterly", status: "active", period: "2026-Q3", goal_slug: "ship-dran-v2" }
   })
4. dran_create_todo({
     context: "personal",
     title: "Implement planning hierarchy",
     slug: "implement-planning-hierarchy",
     plan_slug: "q3-2026-plan-ship-dran-v2",
     kanban_status: "this_week",
     priority: "high"
   })
   → repeat for each todo in the plan (goal is derived from the plan — don't set goal_slug)
5. dran_list_pages({ context: "personal", type: "todo", plan_slug: "q3-2026-plan-ship-dran-v2" })
   → see all todos in the plan
6. dran_list_pages({ context: "personal", type: "todo", goal_slug: "ship-dran-v2" })
   → full goal view: todos linked directly + todos under any plan of the goal
7. dran_list_pages({ context: "personal", type: "plan", goal_slug: "none" })
   → find orphan plans that aren't linked to any goal yet
```

### Triage the inbox

```
1. dran_list_pages({ context: "personal", type: "todo", plan_slug: "none", goal_slug: "none" })
   → todos with no plan and no goal (the inbox)
2. For each todo, decide where it belongs:
   dran_update_todo({ context: "personal", slug: "<todo-slug>", plan_slug: "<plan-slug>" })
   → assigns it to a plan (goal derived automatically)
   OR
   dran_update_todo({ context: "personal", slug: "<todo-slug>", goal_slug: "<goal-slug>" })
   → links it directly to a goal (no plan)
```

### Brain hygiene

```
1. dran_lint({ context: "personal" })
   → surface orphans, stale pages, contested knowledge to Álvaro — do not auto-fix
2. For orphans worth keeping: dran_reaugment_page({ context: "personal", slug: "<orphan-slug>" })
   → re-run augmentation to find semantic links
3. For orphans to remove: dran_delete_page({ context: "personal", slug: "<orphan-slug>" })   → after confirming with Álvaro
4. dran_start_agent({ agent_type: "link_gardener", context: "personal", input: "orphaned pages" })
   → proposes typed relations for under-linked pages
```

---

## 10. Common mistakes

- **Creating without searching.** Always dran_search first — run 2-3 variants.
- **Calling `dran_get_page` without searching first.** Find the slug via `dran_search` or
  `dran_list_pages` before reading, unless Álvaro gave you the exact slug.
- **Using `dran_list_pages` in a loop instead of `wiki://index` resource.** The
  resource returns the full index in one call.
- **Using `dran_create_page` for todos.** Use `dran_create_todo` — it handles the todo
  meta shape correctly.
- **Using `dran_update_page` to change todo status.** Use `dran_update_todo` so meta
  merges — `dran_update_page` replaces meta entirely.
- **Creating `semantic` relations manually.** They are automatic — use
  `dran_create_relation` only for `related`, `part_of`, `supersedes`,
  `contradicts`, `embeds`.
- **Using `[[slug]]` wikilinks.** Not supported. Use `![[slug]]` for embeds
  and `dran_create_relation` for explicit links.
- **Treating `dran_ingest_url` as extraction-only.** It stores the page and (with
  inference) extracts content — it's a capture tool, not just a reader.
- **Setting `goal_slug` on a todo that already has `plan_slug`.** The goal is
  derived from the plan — setting both can contradict the plan's goal. Set
  only `plan_slug` (goal comes automatically) or only `goal_slug` (direct
  link, no plan), never both.
- **Passing `status` for `query` pages.** The correct field is `answer_status`.
- **Deleting without confirmation.** Always ask Álvaro — `dran_delete_page` is
  irreversible.
- **Answering from dran_search excerpts.** Read the page with `dran_get_page` first.

---

## 11. Quick checklist

Before `dran_create_page`:
- [ ] Searched 2-3 variants.
- [ ] Right `page_type` and `meta.kind` / enum values (see §8).
- [ ] Slug is kebab-case and unique (or omitted — Dran derives it).
- [ ] Tags are kebab-case, 2-5 items.

After changes:
- [ ] Confirm tool response (page created / updated / deleted).
- [ ] Run `dran_lint` after batches; surface orphans/stale pages to Álvaro — do not
      auto-fix.
- [ ] Use `dran_stats` for dashboards / weekly reviews.
- [ ] For todos: used `dran_create_todo` / `dran_update_todo`, never `dran_create_page` /
      `dran_update_page`.
