# MCP Tool Map

Complete reference of MCP tools, the Brain functions they call, and functions
NOT exposed via MCP.

## MCP Tools → Brain Functions

| MCP Tool           | Brain Function Called                                      |
| ------------------ | --------------------------------------------------------- |
| `search`            | `Brain.search/2`                                          |
| `get_page`          | `Brain.get_page_by_slug/2`                                |
| `create_page`       | `Brain.create_page/1` + `Brain.resolve_wikilinks/1`      |
| `update_page`       | `Brain.update_page/2` + `Brain.resolve_wikilinks/1`     |
| `delete_page`       | `Brain.delete_page/1`                                     |
| `create_todo`       | `Brain.create_page/1` (with todo meta defaults)          |
| `update_todo`       | `Brain.get_page_by_slug/2` + `Brain.update_page/2`       |
| `create_relation`   | `Brain.create_relation_by_slugs/4`                       |
| `delete_relation`   | `Brain.delete_relation_by_slugs/4`                       |
| `get_links`         | `Brain.list_relations_for_page/1`                        |
| `list_pages`        | `Brain.list_pages/1`                                      |
| `stats`             | `Brain.stats/1`                                           |
| `lint`              | `Brain.lint/1`                                            |
| `rename_slug`       | `Brain.relink_wikilinks/3` + `Brain.update_page/2`       |
| `ingest_url`        | `DranWeb.API.IngestController.do_ingest/3`               |

## Brain Functions NOT Exposed via MCP

| Brain Function            | Why Not Exposed                                         |
| ------------------------- | ------------------------------------------------------ |
| `fuzzy_search/2`          | `search` FTS covers 95% of cases. Fuzzy is for typos.  |
| `list_contexts/0`         | Single context (`personal`). Add if multi-context.      |
| `create_context/1`        | Admin operation, not agent operation.                   |
| `delete_context/1`        | Admin operation.                                        |
| `update_context/2`         | Admin operation.                                        |
| `delete_relation/1`       | Replaced by `delete_relation_by_slugs/4` (slug-based).   |
| `graph_data/1`            | Returns nodes + edges for visualization, not agent use.  |
| `list_log/2`              | Audit log. Niche — add if needed.                        |
| `list_page_versions/1`    | Version history. Niche.                                  |
| `get_page_version/2`      | Specific version. Niche.                                 |
| `extract_wikilinks/1`     | Internal utility.                                       |
| `extract_embeds/1`        | Internal utility.                                       |
| `resolve_embeds/1`        | Internal utility (auto-called on page save).            |
| `resolve_links/1`         | Internal utility.                                       |
| `find_backlinks/2`        | Used by `get_links` indirectly.                         |
| `replace_slug_in_body/3`  | Internal utility (called by `relink_wikilinks`).        |

## Enforced Meta Enums

These are validated by `Dran.Brain.PageMeta` per page type. Passing invalid
values causes changeset errors.

### `note.kind`
`thought`, `journal`, `idea`, `meeting`, `question`, `quote`

### `concept.kind`
`technique`, `pattern`, `discipline`, `theory`

### `entity.kind`
`person`, `company`, `product`, `tool`, `place`, `event`

### `reference.kind`
`article`, `paper`, `video`, `podcast`, `book`

### `artifact.kind`
`document`, `code`, `design`, `deliverable`, `file`

### `todo.kanban_status`
`backlog`, `this_week`, `today`, `in_progress`, `done`, `cancelled`

### `todo.priority`
`low`, `medium`, `high`, `urgent`

### `goal.health`
`green`, `yellow`, `red`

### `plan.horizon`
`weekly`, `monthly`, `quarterly`, `yearly`

### `plan.status`
`draft`, `active`, `on_hold`, `completed`, `archived`

## `update_todo` Merge Pattern

`update_todo` is the correct way to change a todo's status, priority, due_date,
or goal_slug. Unlike `update_page` (which **replaces** the entire `meta` object),
`update_todo` **merges** meta:

```elixir
# In mcp.ex execute_tool("update_todo", ...)
existing_meta = todo.meta || %{}

new_meta =
  existing_meta
  |> maybe_put_meta("kanban_status", args["kanban_status"])
  |> maybe_put_meta("priority", args["priority"])
  |> maybe_put_meta("due_date", args["due_date"])
  |> maybe_put_meta("goal_slug", args["goal_slug"])

attrs = %{"meta" => new_meta, "updated_by" => "agent"}
Brain.update_page(todo, attrs)
```

This means: if a todo has `{kanban_status: "this_week", priority: "high", goal_slug: "dran-mvp"}`
and you call `update_todo` with `kanban_status: "done"`, the result is
`{kanban_status: "done", priority: "high", goal_slug: "dran-mvp"}` — priority and
goal_slug are preserved.

Contrast with `update_page` which would set meta to `{kanban_status: "done"}`
and **lose** priority and goal_slug.

## Upload Storage Layout

Files are stored content-addressed by sha256:

```
priv/static/uploads/{context_id}/{sha256[:2]}/{sha256}.{ext}
```

- Deduplicated automatically (same content = same path)
- Served publicly via `/uploads/...` static path
- Max size: 100 MiB (`UPLOADS_MAX_SIZE`)
- Valid extensions: `png, jpg, jpeg, gif, webp, svg, mp4, webm, mov, mp3, ogg, wav, pdf, txt, md, zip, csv, json, html, js, ts`
- No direct upload via MCP or REST — only via `ingest_url` (remote URLs only, SSRF-protected)

## SSRF Protection in `ingest_url`

`DranWeb.API.IngestController` blocks these IP ranges:
- `127.0.0.0/8` (loopback)
- `10.0.0.0/8` (private)
- `172.16.0.0/12` (private)
- `192.168.0.0/16` (private)
- `169.254.0.0/16` (link-local, includes cloud metadata)
- `0.0.0.0/8`
- `100.64.0.0/10` (CGNAT)
- `::1` (IPv6 loopback)
- `fe80::/10` (IPv6 link-local)

This means `ingest_url` with `http://localhost:...` or any private IP **will fail**.