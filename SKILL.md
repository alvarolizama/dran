---
name: second-brain
description: "Use when operating Álvaro's personal second brain via the Dran MCP server. 18 tools for capturing, relating, querying and maintaining typed knowledge pages (notes, concepts, entities, references, goals, plans, todos, artifacts, comparisons, queries) as a knowledge graph. Triggers on anything Dran / segundo cerebro / brain: thoughts, notes, research, URLs, goals, todos, comparisons, weekly reviews, or delegating longer tasks to agents."
version: 2.3.0
author: Álvaro Lizama
license: MIT
metadata:
  hermes:
    tags: [dran, second-brain, mcp, knowledge-graph, notes, productivity]
    related_skills: [obsidian, notion, apple-notes]
---

# second-brain — MCP User Manual

## 1. What this skill is for

This is the operator manual for Álvaro's **second brain**, accessed exclusively
through the Dran **MCP** (Model Context Protocol) endpoint. Every operation goes
through the MCP tools — there is no need to use the REST API or the web UI.

**Load this skill when:**

- Álvaro mentions Dran, the "segundo cerebro", knowledge graph, notes,
  goals/plans/todos, research, articles/URLs, comparisons, or agents.
- You need to capture, update, relate, or query durable knowledge.

**Do not use for:**

- Ephemeral chat (use the `memory` tool).
- Session-only state.
- Duplicating content that already lives in another canonical system.

## 2. MCP connection

| Item | Value |
| --- | --- |
| Transport | Streamable HTTP, MCP spec 2025-03-26 |
| POST | `POST http://<dran-host>/api/mcp` |
| Auth | `Authorization: Bearer ${MCP_DRAN_API_KEY}` |
| Default context | **`personal`** — do not ask, do not switch unless Álvaro says otherwise |
| Config | `~/.hermes/config.yaml` → `mcp_servers.dran` |

- Requests need an `id` to get a JSON response. Notifications (`method` with no
  `id`) return `202` with an empty body.
- The server returns an `mcp-session-id` header on `initialize`.
- If the endpoint returns `401`, check the env var before assuming Dran is down.

## 3. Core ideas

Dran stores knowledge as a **directed graph** inside a context (workspace):

- **Pages** — typed knowledge nodes (`note`, `concept`, `entity`, `reference`,
  `goal`, `plan`, `todo`, `artifact`, `comparison`, `query`).
- **Relations** — directed links between pages (`semantic`, `related`, `part_of`,
  `supersedes`, `contradicts`, `embeds`).
- **Embeddings** — every page is embedded as a vector. After `create_page` /
  `update_page`, the `PageAugmenter` asynchronously creates **`semantic`**
  relations to the closest neighbours.
- **Quality first** — search before creating, read before answering, prefer
  editing over duplicating.

## 4. Working rules

1. **Search before create.** Run 2-3 related `search` queries before every
   `create_page`. If a relevant page exists, update it.
2. **Read before answer.** When Álvaro asks "what do I know about X?",
   `search`, then `get_page` the top 2-3 results. Do not answer from excerpts.
3. **Infer when obvious, ask when risky.** Infer page type, slug and tags from
   context. Ask before deleting, renaming, or touching identity/finances.
4. **Edit > duplicate.** Updating an existing page is almost always better than
   creating a new one.

## 5. Page types

| Type | Use it for | Subtypes (`meta.kind`) | Key `meta` fields |
| --- | --- | --- | --- |
| `note` | Thoughts, journal, ideas, meetings, questions, quotes | thought, journal, idea, meeting, question, quote | kind, date, author, attendees, resolved, source_ref |
| `concept` | Techniques, patterns, disciplines, theories | technique, pattern, discipline, theory | kind, domain, parent_concept |
| `entity` | People, companies, products, tools, places, events | person, company, product, tool, place, event | kind, aliases, external_url, location |
| `reference` | External sources | article, paper, video, podcast, book | kind, source_url, published_at |
| `artifact` | Files, code snippets, designs, deliverables | document, code, design, deliverable, file | kind, filename, mime_type, storage_path, sha256 |
| `goal` | Objectives with target date | — | health (green/yellow/red), start_date, target_date, team |
| `plan` | Time-horizoned plans | — | horizon, status, period, goal_slug |
| `todo` | Actionable items | — | kanban_status, priority, due_date, goal_slug, assignee |
| `comparison` | Side-by-side analyses | — | entities, criteria, verdict |
| `query` | Questions with answers | factual, conceptual, how_to, opinion | kind, difficulty, answer_status, answered_by |

Default to `note` when unsure. Promote later with `update_page`.

## 6. Creating and capturing knowledge

Use `create_page` for everything except todos. `title` and `slug` are optional:
if omitted, Dran derives them from the first non-empty line of `body`.

```json
{
  "context": "personal",
  "page_type": "note",
  "body": "Today I learned that Elixir's `=` is actually a match operator, not an assignment.",
  "meta": { "kind": "journal", "date": "2026-06-27" },
  "tags": ["elixir", "programming"]
}
```

For todos, always use **`create_todo`** (not `create_page` with `page_type=todo`):

```json
{
  "context": "personal",
  "title": "Refactor MCP controller",
  "slug": "refactor-mcp-controller",
  "goal_slug": "dran-mvp",
  "priority": "high",
  "kanban_status": "this_week",
  "due_date": "2026-06-28"
}
```

After `create_page` / `update_page`, Dran automatically:

1. Extracts/refines `title`, `summary`, `tags` and inline links via inference.
2. Generates and stores an embedding.
3. Creates **`semantic`** relations to similar pages.

Plain `[[slug]]` wikilinks are **not supported**. Use `![[slug]]` only to embed
artifacts (it auto-creates an `embeds` relation), and `create_relation` for
explicit typed relationships.

## 7. Editing, renaming and deleting

| Action | Tool | Notes |
| --- | --- | --- |
| Change title/body/tags/meta | `update_page` | **Replaces** `meta` entirely. Body change bumps `version`. |
| Change todo status/priority/date | `update_todo` | **Merges** `meta`. This is the only way to change todo status safely. |
| Change slug | `rename_slug` | Existing `![[old-slug]]` embeds are not updated automatically. |
| Delete | `delete_page` | **Irreversible**, cascades to relations and versions. Always confirm with Álvaro. |

Example `update_todo`:

```json
{
  "context": "personal",
  "slug": "refactor-mcp-controller",
  "kanban_status": "done"
}
```

## 8. How the graph grows

### Automatic

- **`semantic`** relations are created by `PageAugmenter` based on embeddings.
  Never create them manually.
- **`embeds`** relations are created automatically when a page body contains
  `![[artifact-slug]]`.

### Manual

Use `create_relation` for explicit, directed links:

| Type | Meaning | Example |
| --- | --- | --- |
| `related` | Generic manual link | `learning-elixir` → `elixir` |
| `part_of` | A is part of B | `tummo` → `six-yogas-of-naropa` |
| `supersedes` | A replaces B | `phoenix-1.8` → `phoenix-1.7` |
| `contradicts` | A conflicts with B | `new-study` → `old-study` |
| `embeds` | A embeds B (auto from `![[slug]]`) | — |

Inspect relations with `get_links`.

## 9. Ingesting URLs and files

`ingest_url` saves a URL as a `reference` page, or downloads a file and stores it.
**It does not extract or parse content** — that is your job afterwards with
`web_extract` or by reading the stored file.

```json
{
  "context": "personal",
  "url": "https://example.com/article.html",
  "slug": "example-article",
  "tags": ["research"]
}
```

- SSRF protection blocks `localhost`, private IPs and CGNAT ranges. Do not pass
  local URLs.
- For local files, upload them to a temporary host first, or paste the text into
  an `artifact`/`note` page directly.

## 10. Querying the second brain

| Tool | Purpose |
| --- | --- |
| `search` | Unified search: auto picks FTS, fuzzy, semantic or hybrid. Use `type` filter when you can. |
| `semantic_search` | Deprecated alias for `search` with `strategy=semantic`. Prefer `search`. |
| `get_page` | Full markdown body of one page. Use this to actually read. |
| `list_pages` | Filtered lightweight list (type, tag, status, limit). |
| `get_links` | Inbound + outbound relations for a page. |
| `stats` | Dashboard: totals, pages by type, todos by status, orphans, relations. |
| `lint` | Orphans, stale pages (>90d), contested knowledge. |

### Resources (read-only)

Prefer these over looping `list_pages` when you need an overview:

| URI | Returns |
| --- | --- |
| `page://{context}/{slug}` | Full page markdown |
| `goal://{context}/{slug}` | Goal + linked todos/plans as JSON |
| `wiki://{context}/index` | Full index of the context (slug + title + type) |

## 11. Autonomous agents

For multi-step research or ingest tasks, delegate with `start_agent` and poll
with `get_agent_session`:

- **`research`** — searches/scrapes the web and creates `note`/`reference` pages.
- **`ingest`** — validates/inspects/downloads a URL and creates a `reference`
  page.

```json
{
  "agent_type": "research",
  "context": "personal",
  "input": "Yeshe Walmo"
}
```

There is no dedicated search agent yet; for search-only tasks use `search`
directly.

## 12. MCP prompts

| Prompt | Use |
| --- | --- |
| `research_topic` | Scaffold a research page (outline, sources, questions). |
| `brainstorm` | Generate 5-10 interlinked idea pages. |
| `goal_review` | Review a goal, its todos and plans, suggest next actions. |

## 13. Recipes

### Capture a thought

```
1. search(body keywords, "personal")
2. create_page({ context: "personal", page_type: "note", body: "...", meta: { kind: "thought" } })
```

### Capture meeting notes

```json
{
  "context": "personal",
  "page_type": "note",
  "body": "... notes ...",
  "meta": { "kind": "meeting", "date": "2026-06-27", "attendees": ["Álvaro", "Paty"] }
}
```

### Process a research article

```
1. ingest_url({ url, context: "personal", tags: ["research"] })
2. Read the content with web_extract(url).
3. If valuable, create_page({ page_type: "note", body: "Summary..." })
4. create_relation({ source_slug: "<note>", target_slug: "<reference>", relation_type: "part_of" })
```

### Add a todo to a goal

```
1. search("<goal name>", "personal", type: "goal")
2. create_todo({ title, slug, goal_slug: "<goal>", kanban_status: "this_week", priority: "high" })
```

### Mark a todo done

```json
{
  "context": "personal",
  "slug": "<todo-slug>",
  "kanban_status": "done"
}
```

Use `update_todo`, not `update_page`.

### Weekly review

```
1. stats({ context: "personal" })
2. list_pages({ context: "personal", type: "goal" })
3. goal://personal/<goal-slug> for active goals
4. list_pages({ context: "personal", type: "todo", status: "in_progress" })
5. lint({ context: "personal" })
```

### Create a comparison

```json
{
  "context": "personal",
  "page_type": "comparison",
  "title": "Phoenix vs Rails",
  "body": "...",
  "meta": { "entities": ["phoenix", "rails"], "criteria": ["performance", "concurrency", "ecosystem"], "verdict": "Phoenix for real-time; Rails for CRUD speed." }
}
```

## 14. Common mistakes

- **Creating without searching.** Always search first.
- **Using `create_page` for todos.** Use `create_todo`.
- **Using `update_page` to change todo status.** Use `update_todo` so meta merges.
- **Creating `semantic` relations manually.** They are automatic.
- **Using `[[slug]]` wikilinks.** Not supported. Use embeddings + relations.
- **Treating `ingest_url` as extraction.** It saves/downloads only; you read later.
- **Passing `status` for `query` pages.** Correct field is `answer_status`.
- **Deleting without confirmation.** Always ask Álvaro.
- **Answering from search excerpts.** Read the page with `get_page`.

## 15. Meta validation cheat-sheet

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

## 16. Quick checklist

Before `create_page`:
- [ ] Searched 2-3 variants.
- [ ] Right `page_type` and `meta.kind`/enums.
- [ ] Slug is kebab-case and unique.
- [ ] Tags are kebab-case, 2-5 items.

After changes:
- [ ] Confirm tool response.
- [ ] `lint` after batches; surface orphans/stale pages to Álvaro, do not auto-fix.
- [ ] `stats` for dashboards/weekly reviews.
