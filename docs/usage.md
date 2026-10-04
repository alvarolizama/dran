# Using Dran

How to **use** the app, surface by surface: where each thing lives, how it is
created and edited, who can read it, and what an agent can do through its tools.

Two sources keep this honest: every route below exists in
`lib/dran_web/router.ex`, and every tool exists in
`hermes_plugin/dran/__init__.py` (thin clients over the REST API, so a
non-Hermes agent does the same through `docs/api.md`).

If you are looking for **what each page type is for**, read
[docs/page-types.md](page-types.md) — this document is about operating the
surfaces.

## One instance, one workspace

There is no per-workspace URL prefix and no `/dashboard`. The instance **is**
the workspace: `/` is the workspace home, and every route is flat.

## The destination — who can read an item

One vocabulary, one badge and one control, everywhere an item has a
destination: **pages, custom pages, goals, plans, collections, reports and
memory**.

| Level | Who reads it |
|---|---|
| `private` (the default) | its owner (and instance admins) |
| `public` | everyone on the instance |
| `shared` | only the users and groups you invite |

- The **pill** is the badge you see in a list or a detail. `private` is the
  default and is not announced, so a private item shows no pill.
- The **picker** (three buttons: Private / Public / Shared) is the only
  control. Its shape is the same in every surface; what changes is where it
  lives (the create modal's header, or the edit form).
- **The owner moves the destination** — nobody else. `Shared` is completed by
  the share dialog, which grants read access to specific users and groups.
  Sharing never grants write access: writing stays with the owner.
- A **task has no destination of its own**: it inherits its goal's, and the
  board marks the pill as `inherited`.

## Pages

| What | Where |
|---|---|
| Home | `/` |
| List by type | `/notes`, `/entities`, `/concepts`, `/references`, or your custom type's path |
| Detail | `/:type/:slug` (a slug or the page id) |
| A–Z index | `/letter/:letter` |
| Pinned pages, collections, type index | on `/` |

**Create** — open the list of the type and use `?new=true` (the create modal is
URL state, not a `/new` route). **Edit** — open the detail with `?edit=true`.
The detail itself is read-only rendered markdown (mermaid included).

The destination is chosen in the create modal's header, or in the edit form.
An agent can set it per page (`private | public | shared`).

**Tools.** `dran_create_page`, `dran_get_page`, `dran_list_pages`,
`dran_update_page`, `dran_delete_page`, `dran_search`, `dran_get_links`,
`dran_create_relation`, `dran_delete_relation`, `dran_rename_slug`,
`dran_reaugment_page`, `dran_list_page_types`, `dran_capture` (quick capture
straight into a note).

## Custom page types

| What | Where |
|---|---|
| Declare, disable, remove | `/settings/instance` → **Page types** |

A custom type declares its slug, label, colour, path segment and its own meta
fields. The moment it exists it gets its own sidebar section, list, graph
colour, editor fields and route (`/<path>`) — exactly like a built-in. The four
built-in types cannot be redefined; a disabled type keeps its pages but loses
its section and list.

**Tools.** There is no tool that declares a page type: the agent **uses** the
types it finds (`dran_list_page_types`) and creates pages of any of them
(`dran_create_page` with `page_type`).

## Goals (and their tasks)

| What | Where |
|---|---|
| List | `/goals` (filters `?status=` and `?order=`) |
| Detail | `/goals/:id` (id or slug) |
| Board of one goal | `/tasks/:id` |
| All tasks | `/tasks` |
| Create / edit | `?new=true` (list) and `?edit=true` (detail) |

A goal is the **work container**: its tasks hang from it, and its progress is
**derived** from them (done/total) — never stored. A goal can hold subgoals, and
the detail groups its tasks by status. From the detail you can also open the
board of that goal and create a task in it (`?new_task=true`).

The detail carries the destination pill, the share dialog, and the **related
pages** sidebar (below).

**Tools.** `dran_list_goals`, `dran_get_goal`, `dran_create_goal`,
`dran_update_goal`, `dran_delete_goal`, `dran_list_tasks`, `dran_get_task`,
`dran_create_task`, `dran_update_task`, `dran_move_task`, `dran_delete_task`,
`dran_capture` (a task with no goal lands in its owner's inbox).

## Plans

| What | Where |
|---|---|
| List | `/plans` (filters `?status=` and `?order=`) |
| Detail | `/plans/:id` (id or slug) |
| Create / edit | `?new=true` (list) and `?edit=true` (detail) |

A plan carries a **checklist**: an ordered list of steps edited in the detail
(add, remove, reorder, tick). Progress is **derived** from it (done/total),
exactly like a goal's is derived from its tasks. Ticking a step rewrites the
checklist with an optimistic lock — two hands editing at once get an error
instead of overwriting each other.

The detail carries the destination pill, the share dialog, and the **related
pages** sidebar.

**Tools.** `dran_list_plans`, `dran_get_plan`, `dran_create_plan`,
`dran_update_plan`, `dran_delete_plan`, `dran_set_plan_checklist`,
`dran_toggle_checklist`.

## Related pages (goals, plans and pages)

The detail of a goal or a plan has a sidebar that answers *"what does this
touch?"* with **two sources, never mixed**:

1. the **real relations** of the graph (the ones you or an agent declared);
2. only if there are none, a **semantic suggestion** (`title + summary`, with a
   distance threshold).

The panel **declares which source it is showing** — *From the graph*,
*Suggested*, or *None*. It reads with the reader's own reach: a page you cannot
read never appears, by either route.

Linking is **explicit**: a picker creates the relation, and it is attributed to
whoever created it. The sidebar never writes a relation on its own.

**Tools.** The relation itself is the same graph edge pages use:
`dran_create_relation` and `dran_get_links`.

## Memory

| What | Where |
|---|---|
| List and search | `/memory` |

Memory is the **shared fact store**: atomic facts with a trust score, written
by agents and workers through the API, deduplicated per owner. The UI does not
create facts — it reads them live, searches them (hybrid search, which does not
inflate the retrieval counters), filters by status (`Active` / `Stale` /
`All`), rates them (`helpful` / `not helpful`), marks one stale, and purges the
stale ones.

Each fact shows its destination with the same pill and gives its **owner** the
same picker; `Shared` is completed with the same share dialog as pages, goals
and plans.

**Tools.** `dran_memory_add`, `dran_memory_search`, `dran_memory_update`,
`dran_memory_feedback` (plus `POST /api/memory/ingest` to extract facts from a
transcript server-side). Memory visibility is **web-only**: the tools store
private facts and reject a `visibility` parameter, so moving a fact's
destination is a deliberate act in the UI.

## Views

| View | Where |
|---|---|
| Global search | `/search` |
| Activity log | `/activity` |
| Journey | `/journey` |
| 3D graph | `/graph` |
| Reports (system-generated) | `/reports/:slug` |
| Collections (saved queries) | `/collections`, `/collections/new`, `/collections/:slug` |

The 3D graph draws pages, memories **and work entities**: goals and plans are
nodes with their own colour, and they read with the reader's own reach. Its
legend doubles as a type filter.

## Services

The user's own apps, connected to their account and used by their agent:
mail, calendar, issues and pull requests, chat messages, files.

| What | Where |
|---|---|
| Connect, see the state and disconnect your apps | `/services` (fourth block of the nav) |
| Which apps the instance exposes (policy) | `/settings/instance` → Services (owner) |
| Whether the integration is configured | `/admin/system` → Services (read-only + test connection) |

- **The state is a lifecycle**: `INITIATED` (you opened the link, the consent is
  not complete) → `ACTIVE` (it runs) / `EXPIRED` (reconnect issues a NEW link);
  `INACTIVE` does not run tools. It is read from the provider every time — the
  return trip from the consent carries no authority.
- **Connecting is a trip to the provider**: dran emits a hosted link, the
  provider collects the consent and keeps the credentials (dran never sees a
  Gmail/Slack token). The link lives 10 minutes.
- **The vocabulary is connect / reconnect / disconnect** — there is no pause.
  Disconnecting *deletes* and revokes upstream: it cannot be undone, and the UI
  says so before doing it.
- **A connection belongs to its owner**: only that person runs against it, and
  the agent runs with that person's credential.
- **Everything the agent runs goes through dran**, so a call leaves a record
  (which tool, which agent, the provider's `log_id`) — not only the calls that
  worked.

## Settings

| What | Where |
|---|---|
| Your account and API key | `/settings/account` |
| Instance policy (page types, features, tuning, users) | `/settings/instance` |
| Administration (users, groups, models, system, jobs) | `/admin` |

## What an agent can do

The agent surface is the Hermes plugin (`dran_*`): 37 tools for knowledge and
work, plus 4 memory tools. Every one is a thin client over the REST API
([docs/api.md](api.md)), so any agent with an API key has the same reach.

The rules the tools obey:

- **An agent reads with exactly the reach of its owner.** A key is not a way
  around visibility: a private page of another user does not exist for it.
- **Writes are attributed.** The owner is resolved server-side from the
  credential, never from the body.
- **Destinations are explicit.** Pages accept `visibility`; memory does not
  (`422`) — that one moves in the UI.
- **No tool declares page types, moves a fact's destination, or grants a
  share.** Those are instance-level decisions, and the UI is where they live.