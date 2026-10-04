---
name: dran-dev-ui-tweaks
description: "Use when tweaking Dran Web UI from inspector snippets."
---

# Dran UI tweaks from inspector snippets

The user drives small UI changes by pasting browser element-inspector
snippets (tag, selector, HTML) plus a short instruction. Turn each snippet
into a surgical HEEx edit; never restyle beyond the ask.

## Procedure

1. Map the snippet to source: the `data-phx-loc` / `@caller` comments in the
   pasted HTML name the exact template and line (e.g.
   `lib/dran_web/components/layouts.ex`). Read that region before editing.
2. Grep the TEST tree for the old class string / href before changing it —
   component tests assert on literal classes (`assert html =~ "justify-end"`),
   so a class swap breaks a test you haven't run yet. Update the test in the
   same wave to assert the new shape.
3. Patch the HEEx in place (`patch`, not rewrite). Icons are `<.icon
   name="hero-…">` spans inside `<a>` blocks; keep the `:if` guards attached
   to the right link when reordering.
4. Gate with `mix precommit` (compile + full suite) — sidebar/component
   tests live in `test/dran_web/components/`.

## Split layouts (groups + flexible space + divider)

For "X a la izquierda, resto a la derecha con separación": two inner
`flex gap-1` groups inside the outer `flex items-center gap-3`, the divider
is `<div class="ml-auto self-stretch my-1.5 w-px bg-base-300" aria-hidden="true">`
between them. Mirror the divider's `:if` on the group that depends on the
same condition so it never dangles alone.

## Sidebar nav sub-sections (moving an item between blocks)

The workspace nav is THREE labelled `<details>` sub-sections built in
`workspace_groups/3` (`layouts.ex`) — `views` (Home · Graph · Journey · Board),
`goals-plans` (Goals & Plans: objectives of life or personal, not only work) and
`knowledge-base` (page types · Clusters · Memory) — and each one renders
`data-nav-block="<key>"`, which is what the tests assert on. "Put X under Y /
below Z" = move the item's map between the `view_items` / `work_items` /
`page_type_items` lists inside the group it belongs to.

The move always lands in FOUR places in the same wave, or the suite goes red:
`test/dran_web/components/sidebar_nav_test.exs` (pins the label order via
`group_labels/1`, each block's contents via `slice/3`, and that every block has
exactly ONE `<summary>`), `test/dran_web/live/instance_shell_test.exs` (block
order + membership on the real `/plans` render), the comments in
`workspace_groups/3`, and DESIGN §T2. A NEW section label needs its msgid in the
Spanish catalog: `mix gettext.extract --merge`, add the ES string to the `ES`
dict in `scripts/fill_es_gettext.py` (and delete the dead key of a renamed
label), run that script — the merge leaves a `fuzzy` entry with a bogus guess
("Views" → "Ver") and Gettext IGNORES fuzzy, so skipping the script ships English
in a Spanish UI and `test/dran_web/i18n_test.exs` fails on both counts. A label
containing `&` lands in the DOM ESCAPED (`Goals &amp; Plans`): compare it in
tests through the `rendered_msgid/1` helper (html_escape + safe_to_string), not
against the raw `gettext` string.

## ONE modal for a task across surfaces (`DranWeb.TaskComponents`)

"Edit task en el goal no es igual que en el board → estandarizar" = one module,
not two parallel templates. `task_modal/1` composes `resource_modal/1` +
`task_form/1`, and BOTH LiveViews call it (`goal_live.ex`, `task_board_live.ex`);
the per-surface differences come as attrs: `goal_options` (only the board's
CREATE — the detail's goal is the route), `task` (the row → hidden `task_id` +
`lock_version`), `checklist` (only edits; a new task is born without steps),
`on_delete`. Field ids are `"<prefix>-<campo>"`: `goal-task` /
`goal-task-edit-<id>` in the detail, `task` / `task-edit-<id>` in the board —
renaming them means updating the tests that pin those ids.

The save path is a single context use case, `Tasks.save_edit/3`, used by both
handlers: it VALIDATES first (status + content, so a forged select or an empty
title writes nothing) and then writes each field through its own door —
checklist with the form's `lock_version` (RMW: a stale form writes nothing at
all), content by `update_task/2`, status by `move_task/2` with the FRESH lock the
checklist left (that's why the order matters: `move_task` takes the lock from the
struct it receives). Dran's task content is title/body/priority/due_date ONLY:
status and goal are moved by `move_task/2`, never by the content update.

The task BODY uses the house markdown editor (`markdown_body_field`, the same one
goals and plans use) with `hidden_field="task[body]"` and `autosave={false}` —
inside a modal the body is saved by the submit, like goals/plans. It needs the
`workspace_id` assign (wikilinks/uploads): the board had to add it
(`context && context.id`, same as `goal_live`).

Import shared components in `dran_web.ex` with `only:` (`import
DranWeb.TaskComponents, only: [task_modal: 1]`) — a wholesale import collides
with the LiveViews' local helpers (`task_board_live.ex` has its own
`task_form/1`) and `--warnings-as-errors` fails the build.

Two traps seen while doing this:

- A recursive normalizer loops forever when `String.trim/1` returns the SAME
  value (`trim("Después")` → `"Después"` → the binary clause matches again →
  infinite recursion). Trim once and match inside a `case`; the hang presents as
  a DB `ownership_timeout`, because the busy process never returns its connection.
- `form(view, sel, checklist: json)` in `LiveViewTest` is REFUSED when the value
  differs from the rendered hidden input ("value for hidden «checklist» must be
  one of [...]"): hidden values are pinned by the render, so cover the write path
  in a context test and assert only the rendered value in the LiveView test.

## Resource index (card chips + filters) — /goals and /plans are ONE molde

The index is `resource_list_header` + `resource_filters` + `resource_card` +
`resource_empty_state`, all in `ResourceComponents`. Rule: **never paint a card
chip in the LiveView** — pass `progress`, `due_on`/`overdue?` and `visibility` to
`resource_card` and let it render progreso/vencimiento/destino in order; the
surface's OWN chip (a goal's horizon, which a plan does not have) goes in the
`footer` slot with the same chip classes. Test anchors: `data-chip="progress"`,
`data-chip="due"`, `<card-id>-visibility`.

Ordering vocabulary lives in `Dran.ListOrder` (`due` = `asc_nulls_last`, so
what has no date falls last; `updated`; `title`). The index passes `status:` /
`order:` to the context and keeps BOTH in the URL the way the board does: a
`phx-change="filter"` form → `push_patch` to a query built from a fixed
`@query_fields` list with `URI.encode_query/1`, `filters_from/1` dropping
anything outside the vocabulary, and the DEFAULT order omitted (`?order=due`
never appears). With a filter that returns nothing the collection empty state
must stay hidden — that empty state is the one that offers to create.

Touching the molde lands in: `resource_components.ex`, BOTH LiveViews
(`goal_live.ex` / `plan_live.ex`) and their tests, DESIGN §T3.2, and the es
catalog (extract + `scripts/fill_es_gettext.py`) — every new label needs its
Spanish string or `i18n_test` fails.

## Duplicated renderings ("estos quitarlos, solo usar los de abajo")

When the comment points at one of TWO renderings of the same data (a plan's steps
list above its steps editor, a summary list above its form), removing the
highlighted one is only half the job: the event handler behind it becomes
unreachable (a `phx-click` no element fires any more) and has to go with it, and
every test that pinned the removed anchors (`#<id>-toggle-0`, `#<id>-2`) must be
re-pointed at the surviving UI — assert the RETIRED ids are gone
(`refute has_element?(view, "#plan-steps-list")`) so the duplicate cannot creep
back. The context function the handler used stays: it is a domain door (the REST
endpoint still calls `Plans.toggle_checklist/3`). `mix gettext.extract --merge`
then drops the msgids that only that handler referenced — delete those dead keys
from the `ES` dict in `scripts/fill_es_gettext.py` or the next run re-adds
strings nothing renders. Note `render_submit(view, "event", params)` bypasses the
rendered hidden input: the form-based `render_submit/2` REFUSES a value that
differs from what the page rendered (a client-side editor's JSON never matches).

## Destino del recurso (visibility picker) dentro del modal

The picker is `<.resource_scope_field>` and lives in ONE place per surface: the
modal HEADER (next to the ✕) on create, inside the form on inline edit. The
modal header is OUTSIDE the `<form>`, so the radios carry
`form={@form_id}` — the HTML `form` attribute is what makes them travel on
submit, exactly like the footer's save button. `compact` drops the label and the
caption; the body form is called with `with_scope={false}` so the control is not
rendered twice. Tests can only prove the wiring, not the association: assert
`#<modal-id>-header-actions input[name='<res>[visibility]'][form='<form-id>']`
AND that the picker is NOT inside the form (`refute #form #picker`) — a
LiveViewTest form submit reads only fields inside the form element, so nothing
here fails if the association breaks in a real browser.

## A state-changing control inside a list row (select) — move it to the edit modal

When a comment points at a per-row `<select>` that changes state ("quitarlo, esto
solo en editar; el modal de editar debe tener el contenido igual que el crear")
the fix is THREE things, not one: drop the row control, delete the event handler
it fired (nothing else calls it any more) and put the field in the EDIT modal so
it mirrors the CREATE modal field for field (title · status · priority · date).
Keep the DOMAIN door: the status write still goes through its own context
function (here `Tasks.move_task/2`, which maintains column positions) — the modal
calls it from the content-update handler instead of a second event. Only write it
when the value actually CHANGED, or a plain edit re-stamps the position.

Pitfall worth measuring first: that select iterated `@statuses`, the statuses of
the PARENT resource (goal: draft/active/on_hold/done/archived), while a task's are
backlog/todo/in_progress/done/cancelled — so it rendered a column that did not
exist and the domain rejected every click. Before moving a control, check the
options come from the vocabulary of the thing being changed.

## Machine-owned fields (`summary`): never an input

`summary` on pages, goals and plans is written by agents/workers through the REST
door, or stays empty — so no form asks for it, in create OR edit. Remove only the
`<.input>`: keep `:summary` in the changeset `cast` (that is the machine's door),
and an edit from the UI then leaves the text untouched because a cast ignores what
does not travel. Pin both halves in one test: `refute has_element?(view,
"input[name='goal[summary]']")` on create AND on `?edit=true`, plus the text still
rendering (detail subtitle, index card) and surviving a form edit. Collections are
the exception — their `summary` is a human-written description
(`smart_collection_live`), not a machine field.

## Reorder follow-ups ("inviértelos", "este que sea el segundo")

Later turns reference icons by title/href from fresh snippets — locate the
`<a>` by its `href`/`title` inside the group and swap positions; keep each
link's `:if` guard attached when moving it. When the snippet shows the group
div (not single links), the instruction scopes to that group only.

## Brand icon pipeline (SVG source → transparent PNG)

The icon is authored once as `priv/static/favicon.svg` and rasterized to
`priv/static/logo.png` (app favicon + README logo) and `priv/static/favicon.ico`
(legacy fallback). After ANY edit to the SVG, regenerate with
`python3 scripts/gen_logo_png.py` and `python3 scripts/gen_favicon_ico.py`
(both need `playwright-core` in `scripts/screenshot/node_modules`; the ico
script also needs Pillow).

- **Rasterize by inlining the SVG, not loading it via `file://`.** A headless
  Playwright `setContent('<img src="file://…svg">')` + `waitForSelector`
  times out. Read the SVG text and inline it into the page markup
  (`<div id="wrap">{svg}</div>`), then `locator('#wrap').screenshot(...)`.
- **Transparent background needs `omitBackground: true` AND a transparent
  page.** Set `html,body{background:transparent}` and pass
  `omitBackground: true` to the screenshot, or the SVG's uncovered corners
  render opaque white.
- **To make the icon itself transparent, delete the background shape from the
  SVG source** (the full-bleed `<circle … fill="url(#bg)">`), not the raster.
  Keep the glow filter; drop the now-unused gradient `<defs>`.
- **Verify transparency with PIL, never `vision_analyze`.** The vision tool
  composites the PNG onto white and reports a "solid white background" even
  when alpha is 0. Assert it directly:
  `Image.open(png).convert("RGBA").getpixel((4, 4))[3] == 0`.
- **`static_paths/0` in `lib/dran_web.ex` is an allow-list.** A new static file
  not listed there is never served by `Plug.Static`; the request falls through
  to the router, redirects to `/login`, and the browser silently shows no icon.
  Add the filename there and pin it with `test/dran_web/controllers/favicon_test.exs`
  (asserts `/logo.png` returns 200 + `image/png` + PNG magic bytes).
- **Switching an icon's format touches every render site** — grep the old path
  across `lib/`: `root.html.heex` (`<link rel=icon>`), `layouts.ex` (sidebar
  logo), `dashboard_live.ex` (launcher logo), the README header, and the
  favicon test. `~p"/logo.png"` is compile-verified, so a missed reference is
  a compile error, not a runtime 404.

## Verifying a render without login credentials

`localhost` isn't reachable from the browser tool, and **no seed creates a
login** — `priv/repo/seeds.exs` seeds content only, and the production seed no
longer exists: the owner is born in the first-run `/setup` screen. There is no
`admin`/`dran` account to curl with. Verify a render by writing a THROWAWAY
ConnCase test, running
it, then deleting it (keeps the tree clean). Session auth needs no
password:

    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:user, "test_user")
    |> Plug.Conn.put_session(:is_owner, true)

Then `{:ok, _view, html} = live(conn, ~p"/")` and assert on the rendered
HTML — `refute html =~ "max-w-3xl"`, `assert html =~ ~s(href="/settings/account")`,
`refute html =~ "<old footer class>"`. Run `mix test
test/tmp_verify_*_test.exs` then `rm` the file. `async: false` so it can
read the seeded default workspace.

## Pitfalls

- The inspector often returns the SAME element several times when the user
  tried to capture several — five identical snippets carry order info for
  ONE icon only. If the requested ordering is genuinely ambiguous, ask with
  `clarify` (list the candidate orders); don't guess a permutation and wait
  for the correction.
- Visibility is conditional: many icons carry `:if` role guards (Admin →
   `@is_owner`, Workspace → owner/admin of the workspace). When the user
  asks "who sees this", answer from the `:if` + its assign resolution, not
   from the rendered page (which reflects the current user only).
- `localhost` is not reachable from the browser tool (private address) —
  verify UI changes via component tests, not by navigating. See
  "Verifying a render without login credentials" above for the throwaway-test
  recipe.
- **The brand icon ships as PNG, not SVG.** Browsers and GitHub do not
  reliably render the SVG icon, so `priv/static/logo.png` is the favicon AND
  the README header image; `favicon.svg` is only the rasterization source and
  `favicon.ico` a legacy fallback. Never re-introduce an SVG-first
  `<link rel="icon">`: declare `type="image/png" href="/logo.png"` first and
  keep the `.ico` as `rel="alternate icon"` in `root.html.heex`. See the
  "Brand icon pipeline" section for regeneration.
