---
name: dran-dev-page-types
description: "Use when changing Dran page types or kinds."
---

# dran-dev-page-types

Class task: change Dran's page-type surface — add a type, promote/demote
kinds between types, make a type free (`kinds: nil`), or remove one. The
registry (`lib/dran/page_registry.ex`) is the single source of truth; the
work is (1) the registry edit, (2) a data migration when existing rows
move, (3) auditing the ~8 surfaces that hardcode type vocabulary, (4)
updating tests that pin the old contract.

## Procedure

1. **Registry entry.** For each new type add to `@registry`:
   `capabilities: %{graph:, journey:, embeddings:, mcp_create:}` (full
   citizens are all true), `kinds: ~w(...)` or `nil` for a free type, and
   `ui: %{path:, label:, icon:, color:, plural:}`. Append the slug to
   `@types` in the desired sidebar/legend order — everything iterates it.
   Slug stays SINGULAR (internal key, nothing displays it); `path` is the
   free-form route segment (natural plural, or singular for uncountables
   like knowledge/technical — do NOT force-pluralize or rename existing
   slugs for cosmetic uniformity; a rename is a data migration over live
   rows for zero user-visible gain).
2. **Meta fields.** Add a `meta_fields/1` clause per type (tuples:
   `{:select,,label,opts}`, `{:text,,label,opts}`, `{:date,,label[,opts]}`,
   `{:props,,label}`; `condition: {:kind, "x"}` hides unless kind matches).
   Selects need option pairs `{gettext("Label"), "value"}`. New meta KEYS
   must also be added to the `Dran.Knowledge.PageMeta` embedded schema
   (field + `all_fields()` cast list) or the changeset silently drops them.
3. **Kind labels.** Every kind slug needs a `kind_labels/0` entry
   (`"slug" => gettext("Label")`) — `kind_label/1` does `Map.fetch!`, so a
   missing entry crashes list rendering. Kinds dropped from all types but
   still present in rows stay in the map under a "legacy — kept for
   display" comment so old rows render.
4. **Data migration** when existing rows change type: one `execute/2` pair
   per group with SYMMETRIC up/down —
   `UPDATE knowledge_pages SET page_type='x' WHERE page_type='note' AND
   meta->>'kind' IN ('a','b')` and the exact inverse for down. No schema
   change (page_type is app-validated text). Apply on dev, verify the
   repartition with psql `GROUP BY page_type`, then `mix ecto.dump`.
   REMOVING a type: migrate its rows to `note` (the free type) so their
   `meta.kind` survives as a displayable legacy value — do not migrate to
   another validated type unless its kind list contains the values.
5. **Hardcode audit — grep the new slugs AND the old vocabulary across
   these surfaces (each carries its own copy of the enum; no gate compiles
   them):**
   - `docs/page-types.md`: the type table and kind lists
     `"enum" => ["note", ...]` list. Derive BOTH from `mcp_enum()` — the
     enum via `"enum" => mcp_enum()`, the prose via interpolation
     (`"...types: #{mcp_enum() |> Enum.join(\", \")}."`), and the error
     message via `Enum.join(PageTypes.types(), ", ")`. A derived enum
     sitting next to hand-written prose looks wired up but drifts on the
     next type — the model reads the description, not the enum.
   - `layouts.ex` sidebar: derive counts/type_atom from the registry (do
     not hardcode per-type clauses — a derived `type_atom` via
     `path |> String.to_atom()` and a `Map.new(types())` counts map make
     new types zero-touch).
   - `search_live.ex` chips: `type_chip_bg/type_icon_color/type_badge`
     clause-per-type with a catch-all fallback.
   - Graph colors: `PageRegistry.type_colors/0` (map, lookups) AND
     `ordered_type_colors/0` (keyword list, registry order + `"memory"`
     last) — legends render the ordered one so they match the sidebar.
     `GraphHelpers`/`GraphCache`/Journey derive from these; journey uses
     golden-angle hues over `types()`.
   - `assets/js/hooks/graph_3d.js`: `typePaths` map (slug → route segment)
     plus `${type}s` fallback; delete dead slugs (goals/plans/todos) when
     the types die.
   - Moduledocs (`## Page types` lists in page.ex, page_types.ex) and repo
     README/skills: descriptive only — fix stale entries, point at the
     registry as the contract.
6. **Gettext.** `mix gettext.extract --merge`; new msgs land fuzzy/empty —
   fill the es translations (script pass over the .po: set `msgstr`, strip
   the `fuzzy` marker) and keep the `if false do gettext(...) end`
   marker block in the registry listing every type label/plural so
   re-extraction keeps them.
7. **Tests.** Grep test/ for the old enum (`~w(note entity concept
   reference)`, `== N` and `>= N` inventory asserts), for fixtures using
   demoted kinds, AND for the type's URL PATH segment (`"projects"`) —
   list/modal tests iterate path segments, not slugs, so a path grep
   catches fixtures a slug grep misses. `test/dran/page_types_test.exs` pins the EXACT `@types`
   list and order — update it in the same change or the suite fails on it.
   Error-message assertions in `mcp_full_test.exs` embed the vocabulary
   too — derive those (`Enum.join(Dran.PageTypes.types(), ", ")`) instead
   of pasting the list, or they break on every future type.
   Kind-UI tests (filter dropdown, kind select, autosave)
   must run against a KIND-VALIDATED type — a free type renders no kind
   select and no filter, so those tests die on `note` once it is free.
8. **Gates.** `mix precommit` AND `mix assets.deploy` (assets changed:
   JS map and possibly CSS), then grep the BUILT bundle (below).
9. **Doc surfaces en la MISMA wave** — README
   (including the "N page types" count line and the type table),
   `docs/page-types.md` (per-type usage guide + decision DAG), repo
   skills (`skills/dran*/SKILL.md` type lists) y moduledocs citan el
   vocabulario de tipos; actualizarlos junto al registry (ver pitfall
   "Tool DESCRIPTIONS" del skill phoenix-registry-restructure para la
   clase completa). The
   and the `dran_create_page` description derive from the registry /
   live settings — no manual edit needed, but re-read them after the
   change to confirm they render the new type.

## Pitfalls

- **Registry fields that become CSS class names only exist if Tailwind's
  content scan sees them.** The heroicons plugin compiles `.hero-*` classes
  only for class strings found in `@source`-scanned dirs. Icons/colors
  defined in `lib/dran/` (registry) while `app.css` scans only
  `lib/dran_web/` render as empty space — some items get icons (their
  class appears elsewhere in scanned templates) and sibling items don't,
  with zero diagnostics. Fix: `@source "../../lib/dran"`. Verify by
  grepping the BUILT css (`rg -c '\.hero-rocket-launch'
  priv/static/assets/css/app.css`) after `assets.deploy`, never by
  re-reading the registry.
- **`Map.new` does not preserve insertion order — anything rendered from a
  map comes out key-sorted.** A legend built from a colors MAP renders
  alphabetically while the sidebar follows registry order. Do not change
  the map accessor's return type to a keyword list to fix it — lookup
  consumers (`Map.get`, `Map.keys`) break with type warnings and failing
  tests. Keep BOTH: map for lookups, `ordered_/0` keyword-list twin for
  rendering.
- **Free types (`kinds: nil`) silently drop kind UI.** No kind select in
  the editor, no kind-filter dropdown, `kinds(type) || []` everywhere.
  Tests that exercise kind UI on a type being freed must move to a
  validated type (fixtures: create pages of THAT type with its kinds),
  not merely update strings.
- **Promoting a kind to a type that keeps the same name (`project` kind →
  `project` type with a `project` kind inside) is fine — the path is
  free-form, so `projects` needs no double-pluralization.**
- **Verify rendered order/HTML with a throwaway ExUnit file using
  `Phoenix.LiveViewTest.render_component(&Mod.comp/1, key: val)`** —
  calling the component function directly raises
  `raise_bad_socket_or_assign!`. Extract hrefs/attrs with regex from the
  rendered string and `IO.puts` them; delete the file after (it is a
  probe, not a test).
- **`kind_label/1` is `Map.fetch!`** — one unknown kind in a row 500s the
  whole list page. New kinds MUST land in `kind_labels/0` in the same
  commit; render paths may guard with membership + `String.capitalize`
  fallback for legacy values.
- **A kind slug shared across types gets ONE `kind_labels/0` entry — grep
  the map before adding.** Duplicated keys compile to "key X will be
  overridden in map", and precommit runs `compile --warnings-as-errors`,
  so the build fails on a warning long after you moved on.
- **Kind validation does NOT run on persistence.** `Knowledge.create_page`
  casts `meta` as a plain map and never calls `PageMeta.changeset/3` — an
  invalid kind persists fine (pre-existing behavior for every type). Don't
  write a create/reject persistence test; assert kind inclusion via
  `PageMeta.changeset(%PageMeta{}, attrs, "type")` directly.
- **After `mix gettext.extract --merge`, re-read every new msgstr — the
  fuzzy matcher can assign a WRONG translation from a similar msgid**, and
  near-synonyms across locales may collide (two English msgids mapping to
  the same Spanish word); disambiguate deliberately rather than accepting
  the first match.
- **Before diagnosing "the UI/logo is broken" on a served port, verify
  WHICH app owns it** — `lsof -nP -iTCP:PORT -sTCP:LISTEN` then `lsof -p
  PID | grep cwd`. Two Phoenix repos on one machine means the port you're
  looking at may be the other project serving its own assets; run the repo
  under test on `PORT=<other>` and curl it before concluding anything
  about this codebase.
- **Deleting a `@registry` entry by content-match patch can remove the
  NEIGHBOR.** Adjacent entries share ~10 near-identical lines (capabilities,
  ui keys), so a fuzzy old_string spanning the wrong block deletes a
  healthy type and leaves the dead one. Grep the exact line numbers of the
  target entry first (`grep -n '"<slug>" =>'`), re-read that block, and
  match on its unique interior (kinds list, path, color) — then re-grep
  the registry to confirm only the intended entry is gone before
  compiling.
