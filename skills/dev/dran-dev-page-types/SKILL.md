---
name: dran-dev-page-types
description: "Use when changing Dran page types, built-in or per workspace."
---

# dran-dev-page-types

Class task: change Dran's page-type surface. Two very different changes live
here — keep them apart:

| Change | Touches code? | Where |
|---|---|---|
| **Custom type for ONE workspace** (add `recipe`, `trip`, …) | **No** | workspace data: `workspace_page_types` (settings UI / `PUT` on the workspace) |
| **Built-in type** (add, remove, rename, change meta fields) | **Yes** | registry `lib/dran/page_registry.ex` + `lib/dran/workspace.ex` (`@builtin_paths_map`) + migration + docs |

There are exactly FOUR built-in types: `note`, `entity`, `concept`,
`reference`. `meta.kind` **does not exist** — no kind lists, no kind labels, no
kind select, no `?kind=` filter. The type is the only classifier; `meta.props`
carries free-form data. Do not reintroduce a kind layer while working here.

## A. Adding a custom type to a workspace (the common case)

No code, no migration, no deploy:

1. Declare the entry in the workspace's `workspace_page_types` (ordered jsonb
   list; the **settings UI** writes it via
   `Knowledge.update_workspace_settings/2` → `Workspace.settings_changeset/2`,
   which casts and validates the field). Required keys `slug` and `path`;
   optional `label`, `plural`, `icon`, `color`, `meta_fields`.
   **`PUT /api/workspaces/:slug` does NOT write it** — that route goes through
   `Knowledge.update_workspace/2` → `Workspace.changeset/2`, which casts only
   `name/slug/is_default/visibility` and silently drops `workspace_page_types`.
   There is currently no API/plugin route to declare custom types; an agent can
   only READ them (`GET /api/workspaces/:slug/page-types`, tool
   `dran_list_page_types`).
2. Validation is **fail-closed** (`Dran.Workspace.validate_page_types/1`):
   required slug/path, unique slugs, unique paths, slug format
   `^[a-z0-9][a-z0-9_-]*$`, a slug that collides with a built-in is refused,
   the **path** carries the same slug-format check, and the path is rejected
   when it collides with a router-reserved segment (`@reserved_path_segments`:
   `settings api admin notes collections graph memory …`). Failures land on
   `:workspace_page_types` with a precise message — never silently dropped or
   deduped. `path` is EXPLICIT: never blind-pluralize.
3. `normalize_page_types/1` normalizes `icon` to a `hero-` prefix
   (`normalize_icon/1`). That is NOT cosmetic: `<.icon>` has a single clause
   matching `%{name: "hero-" <> _}`, so a declared bare `beaker` raised
   `FunctionClauseError` and 500'd EVERY page of the workspace (the sidebar
   paints the icon). Normalizing on read also repairs already-stored values.
4. The type is immediately effective: `Dran.Knowledge.effective_page_types/1`
   = built-ins ∪ custom (declaration order), which is what the UI renders, the
   write gate validates against, and `GET /api/agent/config` serves to agents.
5. Render the type through the WORKSPACE, not the global registry. Any
   component showing a type's path/icon/label/plural must take the workspace
   and call `Dran.Workspace.page_type_path|icon|label|plural/2`. Reading
   `DranWeb.PageTypes.*` (registry-backed) silently breaks custom types: its
   `path/1` falls back to `slug <> "s"`, so a type declaring `path: "recetario"`
   got its `New` CTA and card links pointing at `/recipes` (dead link) plus a
   generic glyph. Built-ins are the only case where both agree.
6. `meta_fields` entries are JSON arrays (`["text", "key", "Label", opts]`) or
   Elixir tuples in code; opts must have string keys (Jason cannot encode atoms
   or tuples) — `Workspace.normalize_meta_fields/1` is the boundary.

## B. Adding or removing a BUILT-IN type

1. **Registry entry.** Add to `@registry`: `capabilities: %{graph:, journey:,
   embeddings:, mcp_create:}` (full citizens are all true), optional
   `meta_fields/1` clause, and `ui: %{path:, label:, icon:, color:, plural:}`.
   Append the slug to `@types` in the desired sidebar/legend order —
   everything iterates it. Slug stays SINGULAR (internal key, nothing displays
   it); `path` is the free-form route segment.
2. **Built-in path map.** Add the slug → path pair to `@builtin_paths_map` in
   `lib/dran/workspace.ex` (it seeds the UI attrs for built-ins and is the list
   that rejects a custom type redefining a built-in).
3. **Meta fields.** A `meta_fields/1` clause per type; new meta KEYS must also
   be added to the `Dran.Knowledge.PageMeta` embedded schema (field +
   `all_fields()` cast list) or the changeset silently drops them.
4. **Data migration** when existing rows change type: one `execute/2` pair per
   group with SYMMETRIC up/down — `UPDATE knowledge_pages SET page_type='x'
   WHERE page_type='note' …` and the exact inverse for down. No schema change
   (page_type is app-validated text). Apply on dev, verify the repartition with
   psql `GROUP BY page_type`, then `mix ecto.dump`. REMOVING a type: migrate its
   rows to `note` (the free-form type).
5. **`disabled_page_types`.** It still exists and validates against the
   workspace's EFFECTIVE types, not the global list — a workspace that had a
   removed type disabled keeps a stale entry, so clean it in the migration or
   the settings form fails to save.
6. **Gettext.** `mix gettext.extract --merge`; fill the es translations (script
   pass over the .po: set `msgstr`, strip `fuzzy`) and keep the
   `if false do gettext(...) end` marker block in the registry listing every
   type label/plural so re-extraction keeps them.

## Hardcoded-surface audit (built-in changes only)

Grep the new slug AND the old vocabulary across these; each carries its own
copy of the enum and no gate compiles them:

- `mix precommit` fails on `test/dran/page_types_test.exs` — it pins the EXACT
  `@types` list and order.
- `docs/page-types.md` (type table, decision DAG), repo README count/table,
  moduledocs, and the `skills/dran*` type lists.
- `search_live.ex` chips (`type_chip_bg/type_icon_color/type_badge` — clause
  per type + catch-all), `layouts.ex` sidebar, `PageRegistry.type_colors/0`
  (map) AND `ordered_type_colors/0` (keyword list, registry order) — legends
  render the ordered one so they match the sidebar.
- `assets/js/hooks/graph_3d.js`: `typePaths` map (slug → route segment) plus a
  `${type}s` fallback; a custom type with no entry silently builds a broken URL.
- **Agent surfaces**: `hermes_plugin/dran/__init__.py` must NOT hardcode the
  type list — it reads the effective types from `/api/agent/config`
  (`data.page_types`, `data.workspaces[].page_types`, `.page_type_defs`) and
  falls back to the 4 built-ins offline. `DranWeb.API.AgentConfigController`
  composes that payload (`agent_page_type_defs/1`): built-ins first with
  `"builtin": true`, then `Dran.Workspace.page_type_defs/1` with
  `"builtin": false`.
- The router resolves by path: a removed type's path (`/ideas`, `/food`…)
  stops resolving. Decide explicitly between a redirect and a 404.

## Pitfalls

- **An unvalidated `path` is three bugs at once.** It becomes a URL segment
  (`/`, `..`, spaces, or a reserved word like `settings` build routes the
  router resolves elsewhere or nowhere), AND `layouts.ex` does
  `String.to_atom(page_type_path(...))` for the sidebar badge keys — every new
  path permanently interned an atom (unbounded growth → node crash). Validate
  format AND reserved segments; never let declared data reach `to_atom`.
- **A type's route must be built with the workspace slug.** The real shape is
  `/:workspace_slug/:type_path/:slug`: a handler building `"/#{path}/#{slug}"`
  produces a path the router reads as `workspace_slug = <type_path>` and 404s.
  That bug shipped in `smart_collection_live.ex` — grep `"/#{` + `path` when
  touching navigation, and assert on the redirect target in a probe.
- **Registry fields that become CSS class names only exist if Tailwind's
  content scan sees them.** Icons/colors defined in `lib/dran/` render as empty
  space while `app.css` scans only `lib/dran_web/`; fix with
  `@source "../../lib/dran"`. Verify by grepping the BUILT css
  (`rg -c '\.hero-rocket-launch' priv/static/assets/css/app.css`) after
  `assets.deploy`, never by re-reading the registry.
- **`Map.new` does not preserve insertion order — anything rendered from a map
  comes out key-sorted.** Keep BOTH: map for lookups (`Map.get`, `Map.keys`),
  `ordered_/0` keyword-list twin for rendering. Do not change the map accessor's
  return type to fix order — lookup consumers break with type warnings.
- **A custom type's `path` is data, not derived.** Two workspaces may both
  declare `recipes`; nothing global dedupes paths across workspaces, only
  within one list. Redirects and `graph_3d.js` maps assume built-in paths, so a
  custom type needs the fallback to behave.
- **Meta keys are dropped silently.** A `meta_fields` entry whose key is not in
  the `PageMeta` embedded schema + `all_fields()` cast list never persists.
- **Never assume a workspace has a type.** `effective_page_types/1` is
  workspace-scoped: a type valid in one workspace is refused (422, fail-closed)
  in another. Derive from the workspace, not from `Page.all_types/0`.
- **Deleting a `@registry` entry by content-match patch can remove the
  NEIGHBOR.** Adjacent entries share ~10 near-identical lines; grep the exact
  line numbers of the target entry first (`grep -n '"<slug>" =>'`), re-read
  that block, match on its unique interior (path, color, meta fields), then
  re-grep the registry to confirm only the intended entry is gone.
- **Verify rendered order/HTML with a throwaway ExUnit file using
  `Phoenix.LiveViewTest.render_component(&Mod.comp/1, key: val)`** — calling
  the component function directly raises `raise_bad_socket_or_assign!`. Extract
  hrefs/attrs with regex, `IO.puts` them, delete the file after (a probe, not a
  test).
- **Before diagnosing "the UI is broken" on a served port, verify WHICH app
  owns it** — `lsof -nP -iTCP:PORT -sTCP:LISTEN` then `lsof -p PID | grep cwd`.
  Two Phoenix repos on one machine means the port may be the other project.
