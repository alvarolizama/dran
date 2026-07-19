# Dran UX Simplification — Implementation Plan (corrida grande)

> **For Hermes:** Execute wave-by-wave with subagents on disjoint file scopes; parent verifies compile + tests after each wave. Load `elixir-build-troubleshooting` before compiling (dev server holds .beam locks — kill it first).

**Goal:** Simplify Dran's UX end-to-end: no hand-typed slugs anywhere, auto-generated slugs on all pages, progressive forms, one canonical kanban, clean IA, full i18n, slimmer settings, consistent empty states and graph polish.

**Architecture:** Pure UI/UX layer — no schema changes, no new deps. Meta-field system gains a `:slug_select` type rendered as a populated `<select>`; page forms lose the slug field (backend already derives it); `/todos` becomes a list view, `/kanban` the single board; sidebar regroups Planning vs Knowledge; i18n sweep via `gettext/1`; settings slimmed with an Advanced disclosure.

**Tech Stack:** Phoenix 1.8 LiveView, HEEx, Tailwind v4 (tokens `.surface-1/.surface-2/.text-title/.text-heading/.text-caption/.lift`), Gettext, Ecto. NO daisyUI classes (existing `btn`/`select-bordered` classes in app.css are custom-defined — restyle to tokens where touched).

**Decisions (Álvaro, 2026-07-19):**
1. Slugs auto-generated on ALL pages — slug field removed from forms; rename stays via existing `dran_rename_slug` (MCP) and metadata tab.
2. Kanban: `/kanban` is the single canonical board (gains quick-add); `/todos` becomes a simple list/table view; embedded kanban tabs in project/goal/plan stay as-is (already consolidated into filtered `/kanban` links per v6 — verify and keep).
3. Full sweep in one run: core + i18n + settings slim + empty states + graph polish.

**Conventions:**
- `gettext/1` for every user-facing string. Locale default `es`; also add `en` translations in `priv/gettext/en/LC_MESSAGES/default.po` where a matching key exists.
- No daisyUI. Use design tokens. `<.icon>` hero only. `<Layouts.app>` wrapper.
- Verify: `PORT=4099 mix test` (dev server killed first), `mix compile --force --warnings-as-errors`, `mix precommit` at the end.
- Brain auto-slug: `Brain.ensure_title_and_slug/1` (lib/dran/brain.ex:423-445) already derives slug from title — forms just stop sending it.

---

## Wave 0 — Baseline (parent)

- [ ] `ps aux | grep phx.server` → kill dev server; `mix test` green baseline; restart server after.
- [ ] Commit nothing; working tree must be clean before wave 1.

---

## Wave 1 — Link pickers (slugs fuera de la UI)

**Files:** `lib/dran/brain/page_meta.ex`, `lib/dran_web/components/markdown_editor_components.ex`, `lib/dran_web/page_edit.ex`, `lib/dran_web/live/page_new_live.ex`, tests.

### Task 1.1 — `:slug_select` meta field type (subagent A)

**Objective:** Replace free-text `*_slug` meta fields with selects populated by real page titles.

**Files:**
- Modify: `lib/dran/brain/page_meta.ex` — in `meta_fields_for/1` change `{:text, "project_slug", ...}` / `goal_slug` / `plan_slug` to `{:slug_select, "project_slug", "Project", type: "project"}` (and goal/plan equivalents) for todo (:387-405), plan (:349-358), goal (:373-385).
- Modify: `lib/dran_web/components/markdown_editor_components.ex`
  - `meta_fields` gains attr `context_id` (required).
  - Add `:slug_select` clause in the `case type do` (~:186): fetch options via `Dran.Brain.list_pages(context_id, type: type)` (returns non-archived pages; map to `{page.title, page.slug}`), render `<.input type="select" prompt={gettext("None")} options={...}>`.
  - Also add the missing `:number` clause (goals broken — audit finding): `<input type="number">` honoring `step/min/max` opts.
  - Replace raw `<select>`/`<input>` with `<.input>` for select/date/text; selects get `prompt`.
- Modify: `lib/dran_web/live/page_new_live.ex` and every caller of `<.meta_fields>` (search for `meta_fields` usages — `page_edit.ex` edit form too) to pass `context_id`.

**Tests:** `test/dran_web/components/markdown_editor_components_test.exs` (create if missing): render `meta_fields` for "todo" with a seeded project/goal/plan → assert `<select>` with their titles; assert no `<input name="page[meta][project_slug]">` free-text remains. Existing tests must keep passing.

**Acceptance:**
- [ ] New/edit todo form shows Project/Goal/Plan as dropdowns with real titles + "None" prompt.
- [ ] Saving with a selection persists the slug in meta (verify via existing page tests + browser).
- [ ] Goal form renders Target value / Current value / Progress as number inputs.

### Task 1.2 — "Vincular a…" grouping + chips (parent, after 1.1)

**Objective:** Wrap the 3 link fields in a collapsible "Vincular a…" section; chips reveal selects on click.

**Files:** `lib/dran_web/components/markdown_editor_components.ex`
- Group fields whose key ends in `_slug` (and type `:slug_select`) into a `<details open={any_link_set?}>` block with icon `hero-link` + label `gettext("Link to…")`.
- Chip pattern: each unset link renders a chip button `+ Project` (`phx-click` JS toggle showing its select); set links render the select directly with current value.
- Pure client-side show/hide via `JS.toggle` — no new server state.

**Acceptance:**
- [ ] Fresh todo form shows a single collapsed "Vincular a…" row instead of 3 empty inputs.
- [ ] A todo with links shows them expanded with values.

---

## Wave 2 — Slugs autogenerados + form progresivo

### Task 2.1 — Remove slug field from forms (subagent B)

**Files:**
- Modify: `lib/dran_web/live/page_new_live.ex` — delete slug `<.input>` (:46-52), delete `slug_touched` logic (:160-161) and `ensure_slug` (:258-265); rely on `Brain.ensure_title_and_slug/1`. Keep `unique_slug` fallback (extract shared helper — see 2.3).
- Modify: `lib/dran_web/page_edit.ex` — remove slug input from edit form if present; slug shown read-only in metadata tab only.
- Modify: `lib/dran_web/live/todo_live.ex` quick-add — already slugless; keep.

**Tests:** update `test/dran_web/live/page_new_live_test.exs` — remove slug-related cases, assert creating with only a title produces a slugified slug (`Dran.Slug.slugify/1`).

**Acceptance:**
- [ ] No slug input anywhere in create/edit UI.
- [ ] Creating "Mi Nota Nueva" yields slug `mi-nota-nueva`; duplicates get unique suffix.

### Task 2.2 — Progressive disclosure + smart defaults (subagent B, same files)

**Files:** `lib/dran_web/live/page_new_live.ex`, `lib/dran_web/page_edit.ex`, `lib/dran/brain/page_meta.ex`
- New-page form default visible: Title + Content (+ Tags). "Más opciones" `<details>` wraps Summary + meta_fields.
- Smart defaults injected in mount/handle_params meta: note → `kind: "thought"`, `date: Date.utc_today()`; todo → `kanban_status: "backlog"`, `priority: "medium"`; project/plan → `status: "draft"`; goal → `health_source: "derived"` (and hide `health_source` from the form — internal detail).
- Goal form split: on `:new` show capture fields only (Metric, Target value, Start/Target date, Project); tracking fields (Current value, Progress, Health) only in edit. Implement via `meta_fields_for(type, :new | :edit)` arity-2 (default :edit keeps current behavior).

**Tests:** assert new-note form renders `thought` preselected; new-goal form does NOT render Progress; edit-goal does.

**Acceptance:**
- [ ] New page = title + content + tags visible; everything else behind "Más opciones".
- [ ] Defaults preselected as above; saving a blank todo works with backlog/medium.

### Task 2.3 — Extract `Dran.Brain.Slug` helper (parent)

- Move `unique_slug`/`slugify` duplicates (`page_new_live.ex:267-294`, `todo_live.ex:680-707`) into `Dran.Slug` (extend existing module) or `Dran.Brain.Slug`; update callers; delete copies.

---

## Wave 3 — Kanban consolidation

### Task 3.1 — `/kanban` gains quick-add (subagent C)

**Files:** `lib/dran_web/live/kanban_live.ex`
- Add toggleable quick-add form (Title + Priority + Due + Goal select, same fields as current todo_live quick-add) with `kanban_status` selector defaulting to `backlog`; create handler reuses `Brain.create_page` with unique slug helper.
- Autofocus title (`phx-mounted={JS.focus()}`), Enter submits.
- Respect active filters: if a project/goal/plan filter is active (single slug, not All/None), pre-set that link in the new todo's meta.

**Tests:** `test/dran_web/live/kanban_live_test.exs` — quick-add creates todo in backlog; with `?goal=foo` filter active, todo gets `goal_slug=foo`.

### Task 3.2 — `/todos` becomes list view (subagent C)

**Files:** `lib/dran_web/live/todo_live.ex`
- Replace board render (:52-150 approx) with a clean list/table: columns Title, Status (badge), Priority, Due, Goal (title), actions. Keep status quick-change buttons per row, keep archived toggle section, keep `TodoLive.Show` routes (`/todos/:slug` untouched).
- Remove `@kanban_columns`, drag-drop hook markup, quick-add form (moved to /kanban), node/graph code if unused.
- Keep `data-testid="todo-list"`.

**Tests:** rewrite `todo_live_test.exs` index cases: list renders todos with status badges; status button updates meta; archived toggle works. Drag-drop tests move/delete accordingly.

### Task 3.3 — Sidebar + router (parent)

- Sidebar: rename nav "Kanban" stays → `/kanban`; change "Todos" entry (if any) and dashboard quick-access "Todos" → `/todos` list; counts unchanged.
- No route deletion (both survive with distinct purposes).

---

## Wave 4 — IA / sidebar regroup + navigation affordances

### Task 4.1 — Sidebar regroup (parent)

**Files:** `lib/dran_web/components/layouts.ex` `sidebar_nav/1`
```
Top:        Panel, Kanban, Projects
Planning:   Goals, Plans, Tareas (list)
Knowledge:  Notas, Conceptos, Entidades, Referencias, Colecciones
Outputs:    Artefactos, Comparaciones
Agents:     Investigación, Importar
System:     Contextos, Ajustes, Documentación
```
- Goals/Plans OUT of Knowledge; Smart Collections IN (icon hero-funnel, key "collections" — fixes orphan route + active_nav mismatch).
- Graph/Activity: keep top-level (Álvaro uses graph canvas a lot) but move after Projects.
- Delete dead `counts[:settings]` badge (:318).
- Update dashboard `@nav_groups` to match (single source: extract groups to a shared module `DranWeb.Nav` used by both).

### Task 4.2 — active_nav coverage sweep (subagent D)

- Add correct `active_nav` to the ~13 pages missing it (notes, concepts, entities, goals, plans, todos, references, projects, artifacts, comparisons, queries, page_new, ingest). Mechanical; grep `active_nav` to find gaps. Fix `tag_live.ex` ("tags" → none or map to Knowledge), remove dead `active_nav: "agents"` in `agent_live.ex:421`.

### Task 4.3 — Shared back link + breadcrumbs-lite (subagent D)

- Add `back_link` component in `page_components.ex` (icon + `gettext("Back")` + navigate attr); replace the 13 hand-rolled back buttons.
- `page_detail` header gains context breadcrumb: `PageType plural › Title` (plain text trail, links to list). No history-based back (out of scope).

---

## Wave 5 — i18n sweep completo

### Task 5.1 — gettext in capture flows (subagent E)

**Files:** `page_new_live.ex`, `markdown_editor_components.ex` ("Metadata" label + renderer strings), `page_meta.ex` (ALL labels → `gettext/1` — keep keys in English source, es translation in po), `ingest_live.ex` (whole file incl. `error_to_string`/`format_bytes` outputs), `page_edit.ex` leftovers.

### Task 5.2 — gettext in secondary views (subagent F)

**Files:** `graph_live.ex`, `smart_collection_live.ex`, `tag_live.ex`, `agent_live.ex` (fix "ingest Agent" title, unify labels: sidebar/h1/page_title all `gettext("Importar archivos")`), `docs_live.ex` chrome strings, `kanban_live.ex`, `todo_live.ex` leftovers.

**Tests:** spot-check via existing locale tests if any; otherwise `mix gettext.extract --merge` runs clean, `default.po` (es) has no empty `msgstr` for new keys; browser spot check in Spanish.

---

## Wave 6 — Settings slim + polish barrido

### Task 6.1 — Settings slim (parent)

**Files:** `lib/dran_web/live/settings_live.ex`
- Move 3 semantic thresholds into `<details>` "Avanzado" (icon hero-adjustments-horizontal).
- Remove `agent_max_sources` from the form (keep key readable via Settings.get with default; env-only).
- Remove global `research_lang` field; agent form's per-run selector defaults to `Settings.get("research_lang")` (keep the key, hide UI).
- Keep: `agent_max_pages`, `daily_note_enabled`, read-only status sections.

**Tests:** settings_live_test — assert thresholds inputs exist inside details; `agent_max_sources` input absent; saving still persists remaining keys.

### Task 6.2 — Empty states + header sweep (subagent G)

- Create `empty_state` component (icon-in-tinted-square + heading + caption + optional CTA slot) modeled on `search_live.ex:176-204`.
- Apply to: `graph_live.ex` (currently none), `tag_live.ex:73`, `smart_collection_live.ex:59,183`, `context_live.ex:184`, `activity_live.ex:197`.
- Header sweep: `text-2xl font-bold` → `text-title` in `graph_live.ex:234`, `smart_collection_live.ex:49,108,196`, `tag_live.ex:68`, `agent_live.ex:30`, `docs_live.ex:42`; add `text-caption` subtitles.

### Task 6.3 — Graph polish (subagent G)

- 3D toggle: make it a proper segmented control (same idiom as search strategy toggle), label `2D/3D` visible.
- Fix 3D canvas hardcoded `#0f172a` background → theme token (`bg-base-300` or CSS var) so light mode isn't jarring.
- Empty state from 6.2.

### Task 6.4 — Ingest improvements (parent, if time; else cut)

- Add optional Title field (defaults derived), `page_type` select (note/reference/artifact, default note), fix invalid `kind: "file"` → leave blank (or add "file" to `@note_kinds` — prefer blank).
- Wrap literals in gettext (done in 5.1).

---

## Wave 7 — Validación final + docs

- [ ] Kill server → `mix compile --force --warnings-as-errors` → `PORT=4099 mix test` (all green) → `mix precommit`.
- [ ] Browser pass: new-todo (chips + selects), quick-add en /kanban, /todos lista, sidebar nuevo, settings slim, graph light mode, empty states.
- [ ] Screenshots frescos (dashboard, kanban con quick-add, todos lista, new page form, settings) → `docs/screenshots/` + README table.
- [ ] SKILL.md: note slug auto-gen + link selects (agents already use slugs via API — no MCP change needed).
- [ ] In-app docs (`docs_live.ex`): update capture/guide sections (no slug field, "Vincular a…" selects).
- [ ] Commits por wave: `feat: link pickers…`, `feat: auto slugs…`, `feat: kanban consolidation…`, `feat: IA regroup…`, `feat: i18n sweep…`, `feat: settings slim + polish…`, `docs: …`.

---

## Risks / tradeoffs

- **Wave 3 rewrites todo_live heavily** — the file also hosts `TodoLive.Show` and a graph experiment; subagent must only touch `:index`. Parent reviews diff.
- **Removing slug field**: `dran_rename_slug` (MCP) remains the escape hatch; UI rename can come later if missed.
- **meta_fields `context_id` attr**: all callers must pass it — compile will catch misses (required attr).
- **i18n volume**: page_meta labels feed many forms; keep msgids in English so existing es translations map cleanly; run `mix gettext.extract --merge` once at the end of wave 5.
- **No schema changes** — rollback = git revert.

## Open questions (resolved)

- Kanban survivor → `/kanban` board + `/todos` list. ✅
- Scope → full big run. ✅
- Slugs → auto everywhere. ✅
