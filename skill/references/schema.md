# Dran Page Types & Meta Schema

Source of truth: `lib/dran/brain/page_meta.ex` in the Dran repo (`/Users/alvaro/Workspace/repos/dran`).
This file mirrors the enums and fields as of 2026-06-21.

## Page Types (9)

`note` | `concept` | `entity` | `reference` | `artifact` | `goal` | `plan` | `todo` | `comparison`

## Meta Fields by Page Type

### note
| Field    | Type   | Enum / Notes                                     |
| -------- | ------ | ------------------------------------------------ |
| `kind`   | string | `thought` \| `journal` \| `idea` \| `meeting` \| `question` \| `quote` |
| `date`   | date   | YYYY-MM-DD                                       |
| `author` | string | free text                                        |
| `feasibility` | string | (for questions/ideas, optional)            |
| `impact`      | string | (for questions/ideas, optional)            |
| `attendees`   | array  | (for meetings)                             |
| `resolved`    | boolean | (for questions)                             |
| `source_ref`  | string | (for quotes)                                |

### concept
| Field            | Type   | Enum / Notes                                      |
| ---------------- | ------ | ------------------------------------------------- |
| `kind`           | string | `technique` \| `pattern` \| `discipline` \| `theory` |
| `domain`         | string | free text                                         |
| `parent_concept` | string | slug of parent concept (optional)                 |

### entity
| Field          | Type   | Enum / Notes                                      |
| -------------- | ------ | ------------------------------------------------- |
| `kind`         | string | `person` \| `company` \| `product` \| `tool` \| `place` \| `event` |
| `location`     | string | free text                                         |
| `external_url` | string | URL                                               |
| `aliases`      | array  | string list                                       |

### reference
| Field          | Type     | Enum / Notes                                      |
| -------------- | -------- | ------------------------------------------------- |
| `kind`         | string   | `article` \| `paper` \| `video` \| `podcast` \| `book` |
| `source_url`   | string   | URL                                               |
| `published_at` | date     | YYYY-MM-DD                                        |
| `content_hash` | string   | sha256 of content (optional)                      |
| `fetched_at`   | datetime | ISO8601                                          |

### artifact
| Field          | Type    | Enum / Notes                                      |
| -------------- | ------- | ------------------------------------------------- |
| `kind`         | string  | `document` \| `code` \| `design` \| `deliverable` \| `file` |
| `filename`     | string  | original filename                                 |
| `mime_type`    | string  | MIME type                                         |
| `size`         | integer | bytes                                             |
| `storage_path` | string  | `/uploads/{ctx}/{sha256[:2]}/{sha256}.{ext}`      |
| `sha256`       | string  | content hash (dedup key)                          |
| `version`      | string  | artifact version (optional)                       |

### goal
| Field         | Type   | Enum / Notes                                      |
| ------------- | ------ | ------------------------------------------------- |
| `health`      | string | `green` \| `yellow` \| `red` (validated)          |
| `start_date`  | date   | YYYY-MM-DD                                        |
| `target_date` | date   | YYYY-MM-DD                                        |
| `team`        | array  | string list                                       |

### plan
| Field       | Type   | Enum / Notes                                      |
| ----------- | ------ | ------------------------------------------------- |
| `horizon`   | string | `weekly` \| `monthly` \| `quarterly` \| `yearly` (validated) |
| `status`    | string | `draft` \| `active` \| `on_hold` \| `completed` \| `archived` (validated) |
| `period`    | string | free text (e.g. "2026-Q3")                        |
| `goal_slug` | string | optional link to a goal                           |

### todo
| Field           | Type     | Enum / Notes                                      |
| --------------- | -------- | ------------------------------------------------- |
| `kanban_status` | string   | `backlog` \| `this_week` \| `today` \| `in_progress` \| `done` \| `cancelled` (validated) |
| `priority`      | string   | `low` \| `medium` \| `high` \| `urgent` (validated) |
| `due_date`      | date     | YYYY-MM-DD                                        |
| `goal_slug`     | string   | optional link to a goal                           |
| `assignee`      | string   | free text                                         |
| `remind_at`     | datetime | ISO8601                                          |
| `acknowledged`  | boolean  |                                                   |
| `completed_at`  | datetime | ISO8601                                          |

### comparison
| Field      | Type   | Enum / Notes                                      |
| ---------- | ------ | ------------------------------------------------- |
| `entities` | array  | string list of entity slugs                       |
| `criteria` | array  | string list                                       |
| `verdict`  | string | free text                                         |

## Relation Types (5)

| Type          | Meaning                              | Auto-created by       |
| ------------- | ------------------------------------ | --------------------- |
| `related`     | generic connection (default)         | `[[wikilink]]` in body |
| `contradicts` | source contradicts target            | manual (create_relation) |
| `supersedes`  | source replaces/obsoletes target     | manual                |
| `part_of`     | source is part of target             | manual                |
| `embeds`      | source embeds target                 | `![[embed]]` in body  |

## Upload Storage

Files are content-addressed by sha256:
```
priv/static/uploads/{context_id}/{sha256[:2]}/{sha256}.{ext}
```

Served publicly via `/uploads/...` (Plug.Static). Dedup is automatic — same
content = same path. Max size: 100 MiB (`UPLOADS_MAX_SIZE`).

Valid extensions: `png jpg jpeg gif webp svg mp4 webm mov mp3 ogg wav pdf txt md zip csv json html js ts`

`ingest_url` has SSRF protection — blocks localhost, private IPs (10.x, 172.16-31.x,
192.168.x, 169.254.x), CGNAT (100.64-127.x), and IPv6 loopback/link-local.

## MCP Tools (15)

| Tool               | Category | Description                                       |
| ------------------ | -------- | ------------------------------------------------- |
| `search`           | Read    | FTS search across pages (Spanish stemming)        |
| `get_page`         | Read    | Get full markdown content by slug                  |
| `list_pages`       | Read    | List with filters (type, tag, status, limit)       |
| `get_links`        | Read    | Inbound + outbound relations for a page            |
| `stats`            | Read    | Aggregate context statistics                        |
| `lint`             | Read    | Quality report (orphans, broken links, stale)      |
| `create_page`      | Create  | Create a typed page                                |
| `create_todo`      | Create  | Create a todo with kanban defaults                 |
| `create_relation`  | Create  | Create a typed relation between two pages          |
| `ingest_url`       | Create  | Save URL or download file as reference            |
| `update_page`      | Update  | Update page (title, body, tags, meta — replaces)   |
| `update_todo`      | Update  | Update todo (merges meta — status, priority, etc.)|
| `rename_slug`      | Update  | Rename slug + auto-relink all wikilinks           |
| `delete_page`      | Delete  | Delete page by slug (cascades)                     |
| `delete_relation`  | Delete  | Delete relation by slug pair + optional type      |

## MCP Resources (3)

| URI                       | Returns                                    |
| ------------------------- | ------------------------------------------ |
| `page://{ctx}/{slug}`     | Full page markdown                          |
| `goal://{ctx}/{slug}`     | Goal + linked todos + plans as JSON        |
| `wiki://{ctx}/index`      | All pages in context (slug + title + type) |

## MCP Prompts (3)

| Prompt           | Use case                                   |
| ---------------- | ------------------------------------------ |
| `research_topic` | Scaffold research page (outline + sources) |
| `brainstorm`     | Generate 5-10 interlinked idea pages        |
| `goal_review`    | Review goal status + suggest next actions   |

## Brain API (key functions used by MCP)

All in `Dran.Brain` (`lib/dran/brain.ex`):

| Function | Used by MCP tool |
| -------- | ---------------- |
| `get_context_by_slug/1` | All tools (resolve context) |
| `get_page_by_slug/2` | get_page, update_page, delete_page, get_links, update_todo, rename_slug |
| `search/2` | search |
| `list_pages/1` | list_pages |
| `create_page/1` | create_page, create_todo |
| `update_page/2` | update_page, update_todo, rename_slug |
| `delete_page/1` | delete_page |
| `create_relation/1` | create_relation (via create_relation_by_slugs) |
| `create_relation_by_slugs/4` | create_relation |
| `delete_relation_by_slugs/4` | delete_relation |
| `list_relations_for_page/1` | get_links |
| `resolve_wikilinks/1` | create_page, update_page (auto-called) |
| `relink_wikilinks/3` | rename_slug |
| `lint/1` | lint |
| `stats/1` | stats |