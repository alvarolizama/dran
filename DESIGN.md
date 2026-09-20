# DESIGN.md — UI system

The interface standard of the app family that shares **one single visual
language**. This document is the **Commons** — the shared base: theme and
tokens, layout, basic elements, composition, states, conventions and shell.

**How it is used:**

- Every app **copies this file as-is** into the root of its repo as its
  `DESIGN.md` and **appends at the end** its `## Custom — <App>` section with
  what is exclusive to that app.
- The Commons is **not edited** inside an app repo: it changes **here** and
  propagates by copying. If you change something here, change it in every
  `DESIGN.md`.

**Split criterion:** everything that can be shared lives in the **Commons**
(theme and brand, layout and responsive, shell/sidebar/menus, elements and
**buttons by context**, cards, tables, modals, search pickers, charts, states).
Custom is the exception, and each of its blocks says **why** it is not
shareable (mark the real difference, not the taste). If in doubt, it goes to the
Commons.

> **Golden rule of this doc: it reflects the code.** Everything asserted here
> must be pointable at in `lib/<app>_web/…` or `assets/css/app.css`. If the code
> changes, this file changes with it.

---

## C1. Principles

1. **Native daisyUI + Tailwind.** Do not invent components daisyUI already
   ships (`btn`, `card`, `table`, `badge`, `input`, `select`, `alert`, `modal`,
   `dropdown`, `tabs`). Custom CSS only for **global** conventions.
2. **One single theme per app, chosen in `app.css`.** The family runs daisyUI
   **`dim --default`**, declared in `app.css` and in the `data-theme` of
   `root.html.heex`; the concrete values of the theme in use are in
   **Appendix A**. No hardcoded hex/oklch in templates: always the theme vars.
3. **Reuse before creating.** Look at `*Web.CoreComponents` before writing
   markup by hand: inputs, tables, headers, icons are already there.
4. **Verifiable.** Every interactive control carries a stable `id` for tests
   (`has_element?/2`).

## C2. Theme and tokens

```css
/* assets/css/app.css */
@plugin "../vendor/heroicons";
@plugin "../vendor/daisyui" {
  themes: dim --default;   /* ← the family's SINGLE theme (values in Appendix A) */
}
```

```heex
<%!-- lib/<app>_web/components/layouts/root.html.heex --%>
<html data-theme="dim">
```

**Scaffold rule:** if `app.css` came with `themes: false` + `@plugin
"../vendor/daisyui-theme"` blocks, those blocks have to be **deleted** (plus the
theme switcher's JS in `root.html.heex`) when you fix a built-in theme, or the
old theme stays stuck.

Semantic colors (ALWAYS use the vars, never hex/oklch by hand):

| Role | daisyUI utility | Var | Use |
|---|---|---|---|
| App background | `bg-base-100` | `--color-base-100` | base surface |
| Surface 2 | `bg-base-200` | `--color-base-200` | panels, row hover |
| Surface 3 | `bg-base-300` | `--color-base-300` | borders, chips |
| Text | `text-base-content` | `--color-base-content` | + `/50` `/40` for secondary |
| Primary | `btn-primary`, `text-primary` | `--color-primary` | main action, links |
| Secondary | `btn-secondary` | `--color-secondary` | brand accent |
| Accent | `btn-accent` | `--color-accent` | "extra" / active but not primary |
| Neutral | `badge-ghost` | `--color-neutral` | global / no state |
| Success | `badge-success` | `--color-success` | ok, active |
| Warning | `badge-warning` | `--color-warning` | warning / notice |
| Error | `badge-error`, `text-error` | `--color-error` | destructive |
| Info | `badge-info` | `--color-info` | informational |

Radii and borders come from the theme (`--radius-box`, `--radius-field`,
`--border`). Do not hardcode them.

**The theme rules.** Every color in the app — including the **theme logo's**
(favicon/icons that follow the theme) and the charts' — comes from the daisyUI
tokens of the theme declared in `app.css`; no view writes hex/oklch. Changing
theme = changing **one line** (`themes: <theme> --default`) + `data-theme` in
`root.html.heex`: the views are not touched. The concrete values of the theme in
use are in **Appendix A**. The only exception is the **brand** colors (§C2.1),
which do not follow the theme.

### C2.1 Brand (logo and favicon)

Every app's mark is **the family's** and does not follow the theme's primary: it
uses the brand colors in a `#9fe88d → #62efbd` gradient (strokes) with
`#9fe88d` / `#62efbd` / `#6fbb5c` nodes and a `#c9f7be` core. They travel
together in the same commit: `priv/static/favicon.svg` (the source), `logo.png`
(512 with alpha) and `favicon.ico` (16/32/48). If the theme changes, the mark is
**not** recolored: the family's green is what makes the app recognizable.

## C3. Base layout

- The main content goes in a `<main>`; the **shell** (sidebar, drawer, rail) is
  family → **§C12** (each app declares only its sections and options).
- **Page header:** `<.header>` — title (`:inner_block`) + `:subtitle` +
  `:actions`.
- **Filters and actions, aligned to the RIGHT** (`:actions` slot or
  `justify-end`). Never to the left.
- **Wide containers** (tables/panels) wrapped in `overflow-x-auto`.

### C3.1 Responsive (mobile-first)

Every new surface is born usable on a phone; the desktop is the improvement, not
the starting point.

| Rule | How |
|---|---|
| **Shell breakpoint** | **`lg` (64rem)**: below it, navigation lives in the **drawer** (overlay + hamburger); above it, it is fixed and collapsible to a **rail** of icons (§C12) |
| **Content padding** | `p-4 pb-16 sm:p-6` — tighter on mobile |
| **Page headers** | `flex flex-wrap items-center justify-between gap-3`: actions wrap to the next line on small screens |
| **Tables** | always `overflow-x-auto` (§C6): they scroll horizontally, they never break the layout |
| **Grids** | mobile-first: `grid-cols-1 sm:grid-cols-2 lg:grid-cols-3`; **never** start at 2+ columns |
| **Widths** | `w-full min-w-0`; `max-w-*` is for modals and text, not for content |
| **Modals** | overlay `p-4` + card `w-full max-w-*`; the metadata columns are `hidden md:flex` (§C7.2) |
| **Text** | no hard truncation outside tables/cells; truncated text carries a `title` |
| **Actions** | `btn-xs`+ (touch target); row actions keep their `title` (§C6) |

## C4. Basic elements

The primitive controls. Everything else (cards, tables, modals, pickers) is
composed from these.

| Element | Standard class |
|---|---|
| Primary button | `btn btn-primary` (or `<.button variant="primary">`) |
| Secondary button | `btn btn-primary btn-soft` (default of `<.button>`) |
| Neutral / cancel button | `btn btn-ghost` |
| Row action | `btn btn-xs btn-ghost` (+ `title=`) |
| Destructive | `btn ... text-error` + `data-confirm="…"` |
| Badge | `badge badge-sm` + semantic (`badge-primary/success/warning/error/info/ghost/outline/accent`) |
| Removable chip | `badge badge-sm` with an inner `<button>` |
| Text input | `<.input field={@form[:x]} />` (never a hand-written `<input>`) |
| Icon | `<.icon name="hero-…" class="size-4" />` (heroicons, NOT a loose SVG) |
| Toast (flash) | `toast toast-top toast-end z-50` + `alert alert-info/alert-error` |

**Everything goes through `CoreComponents`** — do not build the `<input>` or the
flash by hand:

- `flash` · `button` (with `variant="primary" | nil`) · `input` · `header` ·
  `table` · `list` · `icon` · `show`/`hide` · `translate_error`/`translate_errors`.

**Navigation and surface primitives** (also in `CoreComponents`, so that every
LiveView has them through `use <App>Web, :html`, with no imports):

| Component | What it is | Attributes |
|---|---|---|
| `<.nav_link>` | sidebar/rail link: icon + label + badge | `label` · `icon` · `path` · `active` · `badge` |
| `<.nav_group>` | group label + its links | `label` + slot |
| `<.menu_item>` | menu entry (dropdown, user menu) | `href` · `icon` · `label` · `active` |
| `<.section>` | section: box with header (badge + title + caption) | `title` · `icon` · `caption` + slot |
| `<.modal>` | compact modal (C7.1): ✕ / Escape / click-away | `id` · `title` · `on_close` · `max_w` + slot (the caller gates it with `:if`) |
| `<.empty_state>` | the canonical empty state (C6) | `icon` · `title` · `caption` · `class` + CTA slot |

They were born in admin/settings and in the shell, and were promoted to
`CoreComponents` so that no second copy exists: if a screen needs a nav link, a
section, a modal or an empty state, **use the shared component** — do not write
new markup, and no local helper.

### C4.1 Buttons by context

The same `btn` changes shape depending on where it lives; there is no single
"standard button":

| Context | Shape |
|---|---|
| **Page CTA (create)** | `<.button phx-click="new_x" id="new-x-btn">` + `hero-plus` icon (default = `btn-primary btn-soft`); the kebab id `new-*-btn` is the test anchor |
| **Form submit** | `<button type="submit" class="btn btn-primary btn-sm">` (solid: there the solid is the form's CTA) |
| **Cancel / close** | `btn btn-ghost btn-sm` |
| **Row action** | `btn btn-xs btn-ghost` + `title` (§C6) |
| **Destructive** | `btn … text-error` + `data-confirm="…? This action cannot be undone."` |
| **Filter / period toggle** | `btn-ghost`; active `btn-primary` |
| **Another path** (social sign-in) | `btn btn-outline` |
| **Navigation** | `<.nav_link>` (§C12.3) |

**`btn-outline` is legitimate for "another path"** — the same hierarchy as the
primary one, an alternative route (e.g. "Continue with Google"), not a color
variant.

## C5. Cards

One single shape for a "box" across the family.

```heex
<div class="card bg-base-100 border border-base-300 shadow-sm">
  <div class="card-body p-4">
    <h2 class="card-title text-base">
      <.icon name="hero-…" class="size-5 text-base-content/60" />
      Title
    </h2>
    …
  </div>
</div>
```

- **Base:** `card bg-base-100 border border-base-300 shadow-sm` + `card-body`.
- **`card-body` density** (choose according to the content): `p-4` (dense: lists,
  KPIs) · `p-5` (medium) · `p-6` (forms) · `p-8` (hero).
- **Title:** `card-title text-base` + icon `size-5 text-base-content/60`.
- **Interactive card (clickable):** `hover:shadow-md transition-shadow`.
- **Section card with header** (icon badge + title + caption): each app defines
  its own section box in **Custom**.
- **Modal card:** `shadow-xl` instead of `shadow-sm` (see C7).
- Shadows and radii from the theme (`--radius-box`, `shadow-sm/md/xl`); not by
  hand.

**The same card depending on where it is:**

| Place | Shape |
|---|---|
| Page / section with header | each app's section box (icon badge + title + caption; see **Custom**) |
| Table container | `card` + `overflow-x-auto` (§C6) |
| List / rows | dense `card-body p-4`, row hover, no zebra |
| KPI / stat | `card-body p-4`, number `text-2xl font-semibold`, secondary label |
| Modal | `shadow-xl` + `card-body p-6` (§C7) |
| Empty state | centered `card` with `<.empty_state>` (§C10) |

## C6. Tables

Canonical structure (one single shape across the family):

```heex
<div class="overflow-x-auto card bg-base-100 border border-base-300 shadow-sm">
  <table class="table table-sm">
    <thead>
      <tr>
        <th>…</th>
        <th class="text-right">Actions</th>
      </tr>
    </thead>
    <tbody id="things" phx-update="stream">
      <tr :for={{id, t} <- @streams.things} id={id}>
        <td>…</td>
        <td class="text-right">
          <button phx-click="edit" phx-value-id={t.id} class="btn btn-xs btn-ghost" title="Edit">
            <.icon name="hero-pencil" class="size-3.5" />
          </button>
        </td>
      </tr>
    </tbody>
  </table>
</div>
```

Rules:

- **`table table-sm` always.** Wrapped in `overflow-x-auto` + card. Fixed-width
  columns: `table table-sm table-fixed w-full`.
- **Row hover, no zebra** — a global rule, once per app:
  ```css
  .table tbody tr { transition: background-color 150ms ease; }
  .table tbody tr:hover { background-color: color-mix(in oklab, var(--color-base-200) 60%, transparent); }
  ```
- **Collections with `stream` + `phx-update="stream"`** (never large assigned
  lists). Each row's `id` is the item's.
- **Actions column** at the end, `btn-xs btn-ghost` with `title`.
- **Empty state** (outside the table):
  ```heex
  <div :if={@things_empty?} class="text-center py-12 text-base-content/40">
    <.icon name="hero-…" class="size-10 mx-auto mb-2 opacity-40" />
    <p>No … yet.</p>
  </div>
  ```
- **Raw data never on screen:** own formatters (dates, prices), never a raw
  `Decimal`.

## C7. Modals

The standard pattern = an overlay `div`, **not `<dialog>`**. Closing = flipping
the assign back.

### C7.1 Simple modal (one column)

```heex
<div :if={@show_modal?} class="fixed inset-0 z-50 flex items-center justify-center p-4" id="thing-modal">
  <div class="absolute inset-0 bg-black/50" phx-click="cancel_form" />

  <div class="relative card bg-base-100 border border-base-300 shadow-xl w-full max-w-2xl">
    <div class="card-body p-6">
      <h2 class="text-lg font-semibold mb-4">New …</h2>
      <.form for={@form} id="thing-form" phx-submit="save">
        …
        <div class="flex gap-2 mt-6 justify-end">
          <button type="button" phx-click="cancel_form" class="btn btn-ghost btn-sm">Cancel</button>
          <button type="submit" class="btn btn-primary btn-sm" id="save-thing">Save</button>
        </div>
      </.form>
    </div>
  </div>
</div>
```

### C7.2 Two-column modal (content + metadata sidebar)

For large forms (creating/editing a resource): header (pill + title + ✕),
**two-column body** — main content + a metadata `<aside>` (`w-80 lg:w-96`,
`hidden md:flex`, its own scroll) — and footer. Almost full-screen.

```heex
<div :if={@show_modal?} id="thing-modal-overlay"
     class="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4 sm:p-6"
     phx-window-keydown="cancel_form" phx-key="Escape">
  <div id="thing-modal" role="dialog" aria-modal="true" phx-click-away="cancel_form"
       class="card bg-base-100 border border-base-300 shadow-2xl w-full flex flex-col overflow-hidden
              h-[calc(100vh-3rem)] sm:h-[calc(100vh-4rem)] max-w-5xl">
    <%!-- Header --%>
    <div class="flex items-center justify-between px-5 py-3.5 border-b border-base-300 shrink-0">
      <div class="flex items-center gap-2.5 min-w-0">
        <span class="text-[11px] font-semibold px-2 py-0.5 rounded-full shrink-0 bg-primary/10 text-primary">Resource</span>
        <h3 class="text-base font-semibold truncate">New …</h3>
      </div>
      <button type="button" phx-click="cancel_form" class="btn btn-ghost btn-xs btn-circle" aria-label="Close">
        <.icon name="hero-x-mark" class="size-4" />
      </button>
    </div>

    <%!-- Body: content + sidebar --%>
    <div class="flex-1 min-h-0 flex overflow-hidden">
      <div class="flex-1 min-w-0 overflow-y-auto p-6">
        <.form for={@form} id="thing-form" phx-submit="save">…</.form>
      </div>
      <aside class="hidden md:flex md:flex-col w-80 lg:w-96 shrink-0 border-l border-base-300 bg-base-200/40 overflow-y-auto p-5 gap-4">
        <h4 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">Details</h4>
        …
      </aside>
    </div>

    <%!-- Footer --%>
    <div class="flex items-center justify-between px-5 py-3 border-t border-base-300 shrink-0">
      <div class="flex items-center gap-2">{render_slot(@left)}</div>
      <div class="flex items-center gap-2">
        <button type="button" phx-click="cancel_form" class="btn btn-ghost btn-sm">Cancel</button>
        <button type="submit" form="thing-form" class="btn btn-primary btn-sm">Save</button>
      </div>
    </div>
  </div>
</div>
```

- The **Save button lives OUTSIDE the `<form>`** (in the footer) and points at it
  with the HTML attribute `form="thing-form"` → the `id` must match the
  `<.form>`'s.
- The **metadata sidebar** is `hidden md:flex` (hidden on mobile) and scrolls
  independently (`overflow-y-auto`).

Rules (both):

- **Visible only when the assign exists** (`:if={@form != nil}` /
  `@show_modal?`).
- **Close by backdrop `phx-click` + Escape**
  (`phx-window-keydown` + `phx-key="Escape"`).
- **Widths:** `max-w-md` (confirmations) · `max-w-lg` · `max-w-2xl` (forms) ·
  `max-w-5xl` (two-column modals).
- **Destructive confirmations:** `data-confirm="…? This action cannot be
  undone."` on the button.
- **The verb says what the button does, not the color:** a close ("Cancel",
  "← Back") does not travel in the CTA row, and joining a resource is not
  labeled "Create". The primary/secondary pair expresses hierarchy; the label,
  the action.

## C8. Search pickers and selects

Choose the control with the matrix: how many values? × is the list large (does
it need search)?

| | **1 value** | **N values** |
|---|---|---|
| **Few** (≤ ~10, no scroll) | **C8.1 select** | **C8.5 toggleable badges** |
| **Many** (search) | **C8.3 single combobox** | **C8.4 multi combobox** |

For free text with suggestions (a long catalog, a custom value): **C8.2
datalist**.

### C8.1 Plain select (1 value, no search)

`<.input type="select" options={…} prompt="…" />` — the native `<select>`
(`w-full select`). For a standalone select outside a form:
`<select class="select select-bordered select-sm w-full">`.

```heex
<.input field={@form[:owner_id]} type="select" prompt="Pick…" options={@owner_options} />
```

### C8.2 Datalist (free text + suggestions)

`<.input type="datalist" options={…} />` — a text input with a `<datalist>`: the
person picks from the list **or** types any value.

```heex
<.input field={@form[:model]} type="datalist" label="Model" options={@catalog} />
```

### C8.3 Single combobox (1 value, with search)

Assigns: `<kind>_search` (text), `<kind>_open` (bool), `current_<kind>_id`
(chosen). The pick **mirrors the label and closes**.

```heex
<div class="relative" phx-click-away="close_pickers">
  <input type="text" name="thing[owner_id_display]" value={@owner_search}
    phx-focus="open_picker" phx-value-picker="owner"
    phx-change="owner_search" phx-debounce="200"
    autocomplete="off" placeholder="Search…" class="input input-sm w-full" />
  <div :if={@owner_open and @owner_results != []}
       class="absolute z-50 left-0 right-0 mt-1 bg-base-100 border border-base-300 rounded-lg shadow-lg max-h-60 overflow-y-auto">
    <button :for={o <- @owner_results} type="button"
      phx-click="select_owner_item" phx-value-id={o.id} phx-value-label={o.label}
      class="block w-full text-left px-3 py-2 hover:bg-primary/10 transition-colors">
      {o.label}
    </button>
  </div>
</div>
```

### C8.4 Multi combobox (N values, with search)

Same as the single one, but the pick does **NOT** close and it **accumulates**
ids (`current_<kind>_ids`); the chosen ones are shown as **chips** below the
input (each chip with its own `<button>`/remove icon) and a `✓` on the active
row.

```heex
<div :if={@current_owner_ids != []} class="flex flex-wrap gap-1 mt-2">
  <span :for={id <- @current_owner_ids}
    class="badge badge-sm badge-primary gap-1 cursor-pointer"
    phx-click="toggle_owner" phx-value-id={id}>
    {label_for(id)} <.icon name="hero-x-mark" class="size-3" />
  </span>
</div>
```

### C8.5 Toggleable badges (N values, no search)

For short lists (permissions): `badge` buttons that toggle. State: selected =
`badge-primary` (`badge-accent` for "extra"); free = `badge-outline` + hover.

```heex
<button :for={m <- @models} type="button"
  phx-click="toggle_model" phx-value-id={m.id}
  class={["badge badge-sm transition-all",
          m.id in @granted_ids && "badge-primary",
          m.id not in @granted_ids && "badge-outline cursor-pointer hover:badge-primary/50"]}>
  {m.name}
</button>
```

### Combobox hard rules (they come from real bugs)

1. **The input ALWAYS carries a name** (`name="…"`). Without `name`, inside a
   form, LiveView serializes an empty payload on `phx-change` and the search is
   wiped on every keystroke.
2. The search handler accepts **both shapes** of the payload
   (`%{"value" => q}` and the nested `%{ns: %{field => q}}`) — resolve with
   clauses.
3. **Single pick = mirror the label + close.** **Multi pick = accumulate + stay
   open.**
4. **`phx-click-away` on the wrapper** + `Escape` at form level. Never leave the
   dropdown open as a "zombie".
5. Do **not** use `phx-keyup` to filter (it reopens on Escape release).
   `phx-change` + `phx-debounce` (`200` search · `300` autocomplete).

## C9. Charts

**There is no charting library.** In the family charts are **hand-written SVG in
HEEx** (or bars with `style="height: …%"`); the data is **preprocessed in
Elixir** and the scales are computed on the **server**.

```heex
<%!-- Canonical bar chart: card + svg --%>
<div id="usage-chart" class="card bg-base-100 border border-base-300 shadow-sm">
  <div class="card-body">
    <h2 class="card-title text-base">
      <.icon name="hero-chart-bar" class="size-5 text-base-content/60" /> Usage
    </h2>
    <div :if={@series == []} class="h-40 flex items-center justify-center text-base-content/40 text-sm">
      No data
    </div>
    <div :else class="flex">
      <div class="flex flex-col justify-between text-[10px] text-base-content/50 pr-1 h-40 text-right w-8">
        <span :for={l <- @y_labels}>{l}</span>
      </div>
      <svg viewBox="0 0 400 150" class="flex-1 h-40" preserveAspectRatio="none">
        <rect :for={{row, i} <- Enum.with_index(@series)} x={10 + i * (@bar_width + 4)}
              y={140 - max(row.value / @max_value * 120, 1)} width={@bar_width}
              height={max(row.value / @max_value * 120, 1)} rx="2" class="fill-primary transition-colors">
          <title>{row.label} — {row.tooltip}</title>
        </rect>
        <line x1="10" y1="140" x2="390" y2="140" class="stroke-base-300" stroke-width="1" />
      </svg>
    </div>
  </div>
</div>
```

Rules:

- **No JS charting dependencies** (no apexcharts/echarts/chart.js/d3).
- **Scales on the server:** Elixir helpers (e.g. a `sqrt` scale with a 4% floor
  for bars; a linear scale for the sparkline). The template only paints.
- **Container:** SVG with `viewBox` + `preserveAspectRatio="none"` and a fixed
  height (`h-40`, `h-8`); or bars with `style="height: …%"` inside a fixed
  height.
- **Series color:** from a **named** palette defined in the app (a map of named
  constants, never the hex repeated at the call site). If the color identifies a
  kind of data, it travels in the kind's data — not in a per-slug case table.
- **Axes and labels:** `text-[10px]`/`text-xs`, `text-base-content/40-50`,
  `tabular-nums` on the values.
- **Tooltip:** `<title>` inside the SVG node (or `title=` on the bar).
- **Empty state:** a container of the same height with centered text
  (`text-base-content/40`).
- **Sparkline:** `<svg viewBox="0 0 200 30">` + `<polyline points=… fill="none"
  stroke="currentColor" class="text-primary/40" stroke-width="1.5">`.
- **Hover:** subtle highlight (`group-hover:brightness-110`), no re-render.

## C10. States

| State | Standard |
|---|---|
| Loading | `.skeleton` (shimmer) or `loading loading-spinner` |
| Empty | icon + centered text (`text-base-content/40`) |
| Error | inline `text-error`, or `alert alert-error` |
| Success | flash `alert-info` (toast top-end) |

## C11. Conventions

- **Stable `id`** on every key control (forms, buttons, rows) → `has_element?/2`.
  Form: `id="thing-form"`; row: `id={id}` (from the stream). **The `id` is the
  family's primary convention.**
- **`data-testid` only where there is no natural id:** containers and states
  with no `<form>`/row/stream behind them. `kebab-case`, the variable part last
  after a hyphen, and never as a replacement for an `id` that already exists.
  **Every new testid is born with its consumer in `test/`**: a testid no test
  reads is noise.
- **Assigns per picker:** `<kind>_search` / `<kind>_open` / `current_<kind>_id(s)`.
- **Filters** aligned to the **right** of the header, always.
- **Modals** = an overlay div; closed through an assign.
- **Raw data never on screen:** formatters.
- **Theme:** theme vars only; zero hardcoded hex/oklch (in HEEx and in the JS
  hooks: use `cssColor("--color-…", fallback)`, never a fixed hex).
- **i18n:** `Gettext`.
- An app's gate is **`mix precommit`** (an alias in `mix.exs`).

## C12. Shell (sidebar, navigation and menus)

The family's shell is **sidebar + content bar** (no desktop topbar). Every app
declares its sections and options in **Custom**; the mechanics are these.

### C12.1 Structure

- Root `h-screen` + **daisyUI `drawer lg:drawer-open lg:grid-rows-1 h-full`**.
  **Both** `lg:` classes are structural: the row one has its own hard rule in
  **§C12.5** (without it the whole shell scrolls).
- **The content bar (`h-14`), always visible: it is the ONLY place for the
  navigation toggle.** Below `< lg` it is the hamburger
  (`label for="app-drawer"`) that opens the drawer; at `≥ lg`, the same button
  in the same position collapses/expands the sidebar
  (`label for="sidebar-collapse"`). **Never two controls**: the sidebar carries
  no chevron of its own.
- **Mobile (`< lg`):** the sidebar lives in the drawer (`drawer-side` +
  `drawer-overlay`); closing = overlay or navigating. The drawer is not
  persisted.
- **Desktop (`≥ lg`):** fixed sidebar, **collapsible to an icon rail** (4rem)
  with the `#sidebar-collapse` checkbox (a sibling of `.drawer`): it narrows,
  the texts with `.shell-hide` disappear (brand, selector, search, link and
  group labels, badges, name/email) and **logo + icons** remain, centered, with
  `title` (tooltip). The sidebar is **not** hidden and no floating button is
  used: a `fixed` one covers the page title. In the rail the user menu opens to
  the right and `.drawer-side` loses its clipping (`overflow: visible`) — the
  scroll is carried by the aside's inner `<nav>`.
- Sidebar `w-60 shrink-0 border-r border-base-300 bg-base-200/50 flex flex-col`.
  Density: header `p-3`, search `p-3`, nav `flex-1 overflow-y-auto p-2 flex
  flex-col gap-4`, footer `p-3 border-t`.

### C12.2 Sidebar anatomy

| Zone | Content |
|---|---|
| header | logo + wordmark · context selector (`select select-xs`) |
| search | the context's GET form with a `⌘K` hint |
| nav | always-visible entries + groups (`<.nav_group>`) |
| footer | `<.user_footer>`: avatar + name/email + menu |

### C12.3 Navigation and menus

- **`<.nav_link>`**: `btn btn-sm w-full justify-between font-normal`; inactive
  `btn-ghost text-base-content/80`; **active `bg-primary/15 text-primary
  font-medium hover:bg-primary/20` + `aria-current="page"`**. Do **not** use
  `btn-primary btn-soft` for the active one: it mixes only 8% of the color with
  `base-100` and the pill reads gray. Badge `badge badge-sm` (ghost; primary when
  active). `title` with the label — it is the rail's tooltip.
- **`<.nav_group>`**: label `text-xs font-semibold uppercase tracking-wider
  text-base-content/70`, `px-3 pt-1 pb-1`; groups with `gap-4`, links with
  `gap-1`.
- **User menu** (`#user-menu`, `<.menu_item>`), anchored bottom-left:
  **Workspaces** (→ `/`, always: it is the way back to the listing from any
  URL) · Profile · API keys · *(divider, only with a context)* the context's
  entries · *(divider)* Log out. The active entry: `aria-current="page"` +
  `text-primary`.
- **No duplicated navigation:** if the sidebar already leads to a section, the
  page does not repeat it inside; context actions go in the user menu, not in
  the nav. A page's identity is given by its `<h1>` + caption.

### C12.4 Content padding

The layout sets it: `p-4 pb-16 sm:p-6`. The `pb-16` is the closing air of the
scroll (the last card never sticks to the edge). Never leave content without
padding.

### C12.5 Shell hard rules (they come from real bugs)

1. **The `.drawer` row is bounded: `lg:grid-rows-1`.** daisyUI's `drawer` is a
   grid and declares **only `grid-auto-columns`**: the row stays **implicit** and
   its height is decided by `grid-auto-rows` (default `auto`), so **it inflates
   with the page content**. With long content the WHOLE shell scrolls — the
   content bar and the sidebar go with the wheel, and `main` is left without its
   own scroll — instead of the content scrolling inside while the sidebar stays
   fixed. There are **two equivalent levers** and the family uses both: the
   utility in the markup (`lg:grid-rows-1`, which works because daisyUI already
   ships `grid-row-start: 1` on both children) or the rule in `app.css`
   (`grid-auto-rows: minmax(0, 1fr)` on `.drawer`, which is the general one — it
   also holds if the row were truly implicit, with auto-placed items).
   **One of the two, never neither.** `repeat(1, minmax(0, 1fr))` bounds the row
   to the viewport: the `minmax(0, …)` is what allows shrinking below the
   content. **`lg` scope**, not negotiable: below `< lg` the `.drawer-side` is a
   `position: fixed` overlay and there is no column to bound (mobile behaves the
   same with and without the class).
2. **Do not cover it with `overflow: hidden` on `.drawer`.** The row would keep
   growing (clipping does not bound the size) and it would kill the rail's user
   menu, which opens to the right and needs `overflow: visible` on
   `.drawer-side` (§C12.1).
3. **The one that scrolls is `main`** (`flex-1 min-h-0 overflow-y-auto`), not the
   document. The content bar (`h-14 shrink-0`) and the sidebar stay fixed.

How it is verified (it is measured, not looked at) — with the **compiled** CSS
and long content, at 1440×900 and 1280×800, expanded and in rail mode:

- `documentElement.scrollHeight == innerHeight` (the document does not scroll);
- `main.scrollHeight > main.clientHeight` (the scroll lives inside `main`);
- with the **window** scrolled 400px, the sidebar's `getBoundingClientRect().top`
  is still `0` and so is the content bar's.

Measurement of the real case (2968px of content, 900px window): **without** the
class, drawer row `3024px`, document `3024`, `main` `2968/2968` (no inner scroll)
and sidebar `top: -400` with the window scrolled; **with** the class, row `900`,
document `900`, `main` `844/2968` with inner scroll, and sidebar `top: 0` /
bottom `900`. The same in rail mode (sidebar 240 → 64px) and no differences on
mobile 500×800.

---

## Appendix A — the `dim` theme (reference values)

Source of truth: the `oklch()` values the plugin emits in
`priv/static/assets/css/app.css`. The hex values are an approximate conversion
(no gamut mapping), only to read the table. Contrast = WCAG for the pair with
its `*-content`.

| Token | oklch | ≈hex | Role · contrast |
|---|---|---|---|
| `--color-base-100` | `oklch(30.857% 0.023 264.149)` | `#2a303c` | app background |
| `--color-base-200` | `oklch(28.036% 0.019 264.182)` | `#242933` | panels / row hover |
| `--color-base-300` | `oklch(26.346% 0.018 262.177)` | `#20252e` | chips, borders |
| `--color-base-content` | `oklch(82.901% 0.031 222.959)` | `#b2ccd6` | main text · text 7.9:1 vs base-100 |
| `--color-primary` | `oklch(86.133% 0.141 139.549)` | `#9fe88d` | **main action** (default button) · 13.0:1 |
| `--color-secondary` | `oklch(73.375% 0.165 35.353)` | `#ff7d5d` | brand accent · 7.9:1 |
| `--color-accent` | `oklch(74.229% 0.133 311.379)` | `#c792e9` | "extra" accent · 8.2:1 |
| `--color-neutral` | `oklch(24.731% 0.02 264.094)` | `#1c212b` | dark panels/chips · 9.6:1 |
| `--color-success` | `oklch(86.171% 0.142 166.534)` | `#62efbd` | ok, active · 13.2:1 |
| `--color-warning` | `oklch(86.163% 0.142 94.818)` | `#efd057` | notice · 12.5:1 |
| `--color-error` | `oklch(82.418% 0.099 33.756)` | `#ffae9b` | destructive · 10.8:1 |
| `--color-info` | `oklch(86.078% 0.142 206.182)` | `#28ebff` | informational · 13.0:1 |

`*-content` pairs: `primary-content` `oklch(17.226% 0.028 139.549)` ·
`secondary-content` `oklch(14.675% 0.033 35.353)` · `accent-content`
`oklch(14.845% 0.026 311.379)` · the rest of the semantics carry their pair too.

Theme shape: `color-scheme: dark` · radii `box 1rem` / `field 0.5rem` /
`selector 1rem` · `--border 1px` · `--depth 0` · `--noise 0`.

> **The primary paints every default button.** `CoreComponents.button/1` without
> `variant` emits `btn-primary btn-soft`, so the primary's color is the expected
> one, not a CSS bug. For another color use the explicit utility
> (`btn-secondary`, `btn-accent`) — do **not** redefine the theme's primary.

## Appendix B — verifying an implementation

Adapt the paths to your repo. Every grep corresponds to a rule in the doc:

```bash
grep -n 'data-theme' lib/<app>_web/components/layouts/root.html.heex    # the declared theme (§C2)
grep -n 'themes:' assets/css/app.css                                    # a single `--default` theme (§C2)
grep -rn '@apply' assets/css/                                           # 0
grep -rn 'table-zebra' lib/                                             # 0 (no zebra, §C6)
grep -rn 'overflow-x-auto' lib/                                         # wide tables/panels wrapped (§C3)
grep -c 'for="sidebar-collapse"' lib/<app>_web/components/layouts.ex    # 1 (single toggle, §C12.1)
grep -c 'class="drawer lg:drawer-open[^"]*lg:grid-rows-1' lib/<app>_web/components/layouts.ex  # 1 (drawer row bounded, §C12.5)
grep -c 'grid-auto-rows: minmax(0, 1fr)' assets/css/app.css             # 1 if the lever is CSS (§C12.5)
grep -c 'aside[^>]*label for="sidebar' lib/<app>_web/components/layouts.ex  # 0 (the sidebar carries no toggle of its own)
grep -rn 'p-4 sm:p-6\|p-4 pb-16 sm:p-6' lib/                            # mobile-first padding (§C3.1)
grep -rnE '#[0-9a-fA-F]{3,6}\b' lib/ assets/css/app.css                 # 0 outside brand (§C2.1) and named palettes (§C9)
mix tailwind <app> && grep -c 'data-theme=dim' priv/static/assets/css/app.css  # 1 (§C2)
```

---

## Custom — Dran

Este `DESIGN.md` es el de **Dran** (el segundo cerebro: páginas de conocimiento,
memoria de los workers, grafo y búsqueda). Todo lo de arriba es el **Commons de
la familia**, copiado literal: se edita en el repo `boilerplate` y se propaga
copiándolo — aquí no se toca.

Este bloque declara sólo lo exclusivo de Dran, con el **por qué** de que no sea
compartible, y no repite tablas del Commons: las reglas generales están en su
sección y los valores del tema en uso, en **§Appendix A**.

Dran corre el tema **`dim`**, el único de la familia (§C2): `data-theme="dim"` en
`root.html.heex` y `themes: dim --default` en `app.css`. Al no tener tema propio
no hay paleta que declarar acá.

### Entrada (SPEC-auth)

- **Modo 1** (usuario y contraseña): bcrypt con la ruta *timing-safe*
  (`Bcrypt.no_user_verify/0` cuando el email no existe), throttle de dos capas
  por identificador **y** por IP (`DranWeb.LoginThrottle`), error uniforme.
- **Modo 2** (Google): el botón sólo se renderiza si `Google.configured?/0` — sin
  `GOOGLE_OAUTH_CLIENT_ID` no hay botón.
- **Modo 3 (Umbral SSO): NO adoptado.**
- Primera cuenta: **`/setup`**, que se apaga sola en cuanto existe un usuario.
  La primera cuenta de la instancia **es su owner, por cualquier puerta**: el
  criterio vive en `Dran.Accounts.claims_instance?/0` y lo honran `/setup` y el
  auto-registro de Google (`OAuthController`) — si Google entrara primero sin
  nacer owner, la instancia quedaría con usuarios, sin admin y con `/setup` ya
  apagado (puerta sellada).
- Sesión propia del app (cookie `_dran_key`, `renew: true`): el contrato es
  `SPEC-config.md` §Session and cookies.

### Marca (logo y favicon)

La marca de la familia (grafo hub-and-spokes) con los **colores de marca** de
§C2.1, no con el primary del tema: gradiente `#9fe88d → #62efbd` en trazos y
halo, nodos `#9fe88d` · `#62efbd` · `#6fbb5c`, core `#c9f7be`. Los tres archivos
(`priv/static/favicon.svg`, `logo.png`, `favicon.ico`) viajan en el mismo commit
y **no se recolorean** al cambiar el tema.

### T1. `app.css` (606 líneas) — el design system de Dran

Sólo tema + heroicons + typography + `@custom-variant` de LiveView +
`[data-phx-session]`, **la regla global de tablas** (idéntica a §C6), el bloque
TipTap/mermaid (§T7) y el bloque **"DRAN DESIGN SYSTEM"**:

**Escala tipográfica** (usar estas clases, no tamaños sueltos):

| Clase | Tamaño / peso | Uso real |
|---|---|---|
| `text-display` | 2.25rem / 800, `-0.02em` | hero del dashboard |
| `text-title` | 1.5rem / 700, `-0.01em` | título de página (`<.header>`) |
| `text-heading` | 1.125rem / 600 | título de card/sección |
| `text-body` | 0.875rem / 400 | cuerpo |
| `text-caption` | 0.75rem / 500, `content/55%` | metadata, hints |

Uso observado: `text-caption` (86×), `text-title` (33×), `text-heading` (10×),
`text-display` (4×). Un `<h1>` con `text-lg/xl/2xl/3xl` suelto es deuda.

**Superficies y elevación** (la caja canónica de Dran):

| Clase | Fondo | Sombra | Uso |
|---|---|---|---|
| `.surface-1` | `--color-base-200` | — | paneles hundidos |
| `.surface-2` | `--color-base-100` | `--shadow-surface-2` | **caja canónica de Dran** (29×) |
| `.surface-3` | `--color-base-100` | `--shadow-surface-3` | popovers / destacados |

`.surface-2` (`rounded-2xl` cuando la caja es de sección) es la **caja de
sección** de Dran — exactamente el caso que §C5 deja a **Custom** ("each app
defines its own section box"): caja + badge de icono + título + caption. El resto
de los usos de card (§C5) sí son el `card` del Commons; `card` + `shadow-xl/2xl`
queda reservado a **modales** (§C7).

**Micro-interacciones propias:** `.lift` (translateY −0.5px + shadow-3),
`.skeleton` (shimmer, respeta `prefers-reduced-motion`), `.focus-ring`, y la
regla global `:focus-visible { outline: 2px solid var(--color-primary) }`.
Transiciones `transition-all duration-150`; desplazamientos `hover:translate-x-0.5`.

#### ¿Qué hay de CSS propio? (inventario)

| Bloque | Para qué |
|---|---|
| `@import "tailwindcss" source(none)` + `@source` ×4 | escaneo explícito de clases (v4 no autodescubre) |
| `@import "phoenix-colocated/…"` + `@source` de `_build/dev/phoenix-colocated` | CSS de hooks colocados en LiveView (dev) |
| `@plugin "../vendor/heroicons"` | `<.icon name="hero-…">` |
| `@plugin "../vendor/daisyui" { themes: dim --default }` | el tema (§C2) |
| `@plugin "@tailwindcss/typography"` | `prose` para el markdown de lectura |
| `@custom-variant phx-click-loading` / `phx-submit-loading` / `phx-change-loading` | estados de carga de LiveView |
| `[data-phx-session], [data-phx-teleported-src] { display: contents }` | que los wrappers de LiveView no rompan el layout |
| `.md-editor` · `.editor-toolbar` · `.tb-btn` · `.tiptap …` | editor TipTap (§T7) |
| `.mermaid-rendered` · `.mermaid-codeblock …` | mermaid en lectura y preview (§T7) |
| `.inline-link` · `.wikilink*` · `.embed*` · `.tag-link*` | markdown renderizado y tags (§T7) |
| `.agent-step` (+ `slide-in`) | animación de pasos del worker |
| "DRAN DESIGN SYSTEM": `text-*` · `.surface-*` · `.skeleton` · `.lift` · `.focus-ring` · `:root` vars | escala tipográfica, superficies, estados |
| `.table tbody tr:hover` + `transition` | hover de fila unificado (§C6, la misma receta) |
| reglas de `#sidebar-collapse` sobre `.shell-sidebar` / `.shell-hide` / `.nav-link` / `.shell-sidebar-header` / `.shell-user-footer` (dentro de `@media (min-width: 64rem)`) | colapso a rail de iconos en desktop (§C12.1): el checkbox es el estado, el CSS lo aplica |

**Regla: ningún bloque propio declara color hardcodeado.** Todo color del CSS
custom sale de `var(--color-…)` o `oklch(from var(--color-…) …)` — el tema
provee, el bloque deriva. Si hace falta un color, se usa el token/utility del
tema — nunca hex, oklch crudo ni la paleta cruda de Tailwind.

**Excepciones documentadas** (las únicas):

- **Paleta nombrada del grafo.** Los colores que no son del tema viven en un mapa
  con nombre: `DranWeb.GraphHelpers` (`@neutral_color` `#94A3B8`, `@edge_colors`,
  `@fallback_color`, `@hidden_type_color`) y su espejo en el hook
  (`assets/js/hooks/graph_3d.js` → `NEUTRAL_COLOR`). Es intencional: el canvas
  WebGL no lee vars CSS; el hook las resuelve con `cssColor()`/`oklchAlpha()` y
  los fallbacks son sólo eso, fallbacks. El hex de un **tipo** de página vive en
  el registry o en la config del workspace, nunca aquí.
- **Logo/favicon** (`priv/static/favicon.svg`, `logo.png`, `favicon.ico`): la
  paleta de marca `#9fe88d`/`#62efbd`/`#6fbb5c`/`#c9f7be` (§Custom, arriba). Al
  cambiar el primary del tema, actualizarlos en el mismo commit.

### T2. Shell — lo exclusivo de Dran

La mecánica del shell (drawer, barra con el toggle único, rail, anatomía de la
sidebar, menús, padding) es **Commons: §C12**. Dran aporta lo suyo:

- **Opciones del shell:** `nav={:workspace}` (default) | `nav={:instance}` |
  `sidebar={false}` (sólo login/setup) y `active_nav`. **No existe attr
  `workspaces`**: el shell pinta UN cerebro y el sidebar no tiene selector, así
  que pasarlo era alimentar un attr que nadie leía.
- **Header de la sidebar: logo + wordmark, sin selector de contexto.** En el
  modelo de un solo workspace (la instancia ES el workspace) no hay nada que
  elegir, así que el `select select-xs` de §C12.2 no aplica: la zona gira a la
  **búsqueda** (`#sidebar-search-form`, GET a `/search`, con la pista `⌘K`) y al
  `user_footer`. La caja de búsqueda se renderiza **sólo en el shell de
  conocimiento**: las páginas de instancia pasan `workspace_slug: nil`.
- **Nav de workspace:** bloque de vistas — Home · Graph · Journey — y **Memory en
  su propio bloque** (el nav separa bloques con su `gap`, así que entre Journey y
  Memory queda un hueco: Memory son hechos de los workers, no una vista de
  páginas) + grupo *Knowledge base* (tipos de página + Clusters). **Ninguna acción
  de workspace en el nav**: Activity y Workspace settings viven en el menú de
  usuario.
- **Nav de instancia (`nav={:instance}`):** **Home arriba** (`hero-home`,
  `active_nav="home"` — antes decía «Workspaces» y el destino es el home de
  conocimiento); grupo *Account* (Profile, API keys); grupo *Admin* (Users,
  **Groups**, Models, System, Jobs) — visible para owners. **Sin item
  Overview**: `/admin` sigue existiendo como ruta (impersonation redirige ahí)
  pero el index de cards no es destino. `/settings/instance` y `/admin/*` usan
  este nav; sin él el sidebar cae al de conocimiento y el grupo Admin
  desaparece (era el bug de `/admin/groups`).
  **`/admin/workspaces` no existe** (W6): con una instancia = un cerebro no hay
  contenedores que crear ni que listar, así que el grupo Admin son cinco
  secciones, no seis.
- **`<.user_footer>` (menú de perfil):** Home · Profile · API keys · Activity ·
  Instance settings · **grupo *Admin*** (Users · Groups · Models · System ·
  Jobs, sólo owners) · separador · Log out. El grupo Admin vive **también acá**
  porque el sidebar del shell de conocimiento es el nav de conocimiento: sin él
  `/admin` era inalcanzable desde `/notes` sin escribir la URL.
- **Banner de impersonación** (`root.html.heex`, `id="impersonation-banner"`):
  `bg-warning text-warning-content`, centrado, icono `hero-eye` y botón
  `btn-xs btn-neutral` (`id="stop-impersonating"`).
- **Command palette:** `DranWeb.CommandPalette` (`#command-palette`, `phx-hook`,
  `⌘K`) — overlay `fixed inset-0 z-50 bg-black/50 backdrop-blur-sm`, panel
  `mx-auto max-w-lg rounded-xl border border-base-300 bg-base-100 shadow-2xl`
  (margen superior 15vh), selección `bg-primary/10`.
- **Un solo shell para toda la app:** las páginas de instancia (`/settings/*`,
  `/admin/*`) usan el mismo sidebar con `nav={:instance}`; el contenido (`/` y
  el resto) usa el nav de conocimiento. El flujo topbar (`<.app_topbar>`) fue
  eliminado y `topbar`/`topbar_active` quedan como attrs deprecados no-op.
- **CSS del shell en `app.css`:** el bloque de `#sidebar-collapse` /
  `.shell-hide` / `.shell-collapse-icon` que implementa el rail (§T1). La fila
  del drawer se acota en el markup con `lg:grid-rows-1` (§C12.5: uno de los dos
  lever, nunca ninguno). El invariante medido en §C12.5 (el documento no
  scrollea, `main` sí, la sidebar en `top: 0`) está pinchado en
  `test/dran_web/live/instance_shell_test.exs`.

### T3. Componentes extra

| Componente | Qué es |
|---|---|
| `DranWeb.ResourceComponents.resource_modal/1` | modal **casi full-screen** (`h-[calc(100vh-3rem)]`, `max-w-5xl`) — implementación Dran del patrón **C7.2** (§T3.1) |
| `DranWeb.ResourceComponents.resource_header/1` · `form_actions/1` · `markdown_body_field/1` | header con back-link, fila cancelar/guardar, campo body con editor |
| `DranWeb.MarkdownEditorComponents.markdown_editor/1` | editor TipTap |
| `DranWeb.PageListComponents.page_list/1` · `page_card/1` · `type_badge_label/1` | lista de páginas (agrupada o plana), card de página y badge de tipo |
| `DranWeb.PageComponents.backlinks_section/1` | backlinks de una página |
| `DranWeb.PageComponents.tabs_bar/1` | tabs del detalle (`tab-<tab>`) |
| `DranWeb.PageComponents.graph_3d/1` | hook `Graph3D` (payload JSON + `type_paths`, ver §T6) |
| `DranWeb.PageComponents.page_attributes/1` | panel de atributos/metadata de la página |
| `DranWeb.PageComponents.page_edit_form/1` · `page_new_form/1` | forms de edición y creación de página |
| `DranWeb.VersionDiffComponent` | diff de versiones |
| `DranWeb.ShareDialog` | diálogo de compartición (visibilidad por item) |

> Las primitivas de navegación/superficie (`nav_link`, `nav_group`, `menu_item`,
> `section`, `modal`, `empty_state`) viven en `CoreComponents` (§C4), no acá:
> las comparten shell, admin y settings.

#### T3.1 `<.resource_modal>` — modal de recurso (C7.2)

```heex
<.resource_modal id="page-modal" title="Nueva página" pill="Nota"
  on_close="close_modal" form_id="page-form" submit_label="Guardar">
  <.form for={@form} id="page-form" phx-submit="save">…</.form>
  <:sidebar>…</:sidebar>
</.resource_modal>
```

- Cierra con ✕, **ESC** (`phx-window-keydown` + `phx-key="Escape"` en el overlay)
  y **click-away**, todos → `on_close`.
- El botón **Guardar vive FUERA del `<form>`** (footer) y lo apunta con
  `form={@form_id}` → `form_id` debe coincidir con el `id` del `<.form>` (§C7.2).

### T4. Pickers y buscadores: implementación de referencia

Implementación real del patrón **Commons C8** en Dran:

- **Command palette (⌘K):** `command_palette.ex` — input `phx-debounce="200"`,
  `phx-click-away="close"`, resultados agrupados por tipo con el color del tipo,
  selección `bg-primary/10`. Cumple las reglas duras 1–5 de §C8.
- **Autocomplete de memoria:** `memory_live.ex` — `phx-debounce="300"`; el mismo
  patrón en `workspace_settings_live.ex` (elegir tipo de página).
- **Select nativo (C8.1):** el diálogo de compartición (`share_dialog.ex`) usa
  `select select-sm` para usuario/grupo, con submit on-change. Es el select de
  referencia de Dran; el `select-xs` del header de §C12.2 no aplica (§T2).
- **Búsqueda de la sidebar:** `#sidebar-search-form` — form GET a `/search` con
  `name="q"` y la pista `⌘K`.
- Los colores de chip/icono/badge de un resultado **salen del dato del tipo**
  (`Workspace.page_type_color/2`), nunca de una tabla de casos por slug (§T8).

### T5. Tabla canónica

`<.table>` de `core_components.ex` rendea `table table-sm` (sin zebra; se corrigió
en el commit `6ac1e56`) con soporte `:col`/`:action` e ids de fila por item. La
regla global de hover (§C6) vive una vez en `app.css`, con la misma receta del
Commons: `color-mix(in oklab, var(--color-base-200) 60%, transparent)` — en
daisyUI 5 los alias `--b1/--b2/--b3` ya no existen. Envolver en `overflow-x-auto`
+ caja (§T1: `.surface-2` o `card`) según contexto.

### T6. Gráficas (implementación Dran)

Sin librería (ver **Commons C9**). Tres formas reales:

- **Barras horizontales:** `journey_live.ex` — `style="width: …%; background-color:
  <type color>"` dentro de altura fija; el color viene de `@type_colors` del
  registry (paleta nombrada). Contenedor `.surface-2 p-5 rounded-2xl`.
- **Sparkline:** `journey_live.ex` — `<svg viewBox="0 0 200 30">` + `<polyline
  class="text-primary/40">`; las escalas (`bucket_width/2`, `build_sparkline/1`)
  se calculan en el servidor (§C9: escalas en Elixir).
- **Grafo 3D:** `PageComponents.graph_3d/1` + hook `graph_3d.js` (force-graph).
  El payload (nodos con `color` por tipo, links con color de relación) se arma
  server-side en `GraphHelpers.build_page_subgraph/2`; el hook nunca inventa
  colores — sólo `cssColor()` para vars del tema (fondo del canvas, tooltip,
  links atenuados) y la paleta nombrada espejo (§T1 excepciones).

### T7. Contenido enriquecido

- **Editor TipTap:** estilos `.md-editor`, `.editor-toolbar` (sticky + blur),
  `.tb-btn` (`.is-active` = `bg-primary`), `.tiptap` (tipografía tipo Notion,
  blockquote, code, tablas, selección con tinte primary).
- **Mermaid:** `.mermaid-rendered` (lectura) y `.mermaid-codeblock` (preview inline).
  Hooks: `assets/js/hooks/{mermaid,mermaid_codeblock,graph_3d,markdown_editor}.js`.
- **Solo lectura:** `prose` (plugin `@tailwindcss/typography` cargado) + clases
  propias `.inline-link`, `.wikilink`, `.wikilink-broken`, `.embed` / `.embed-broken`.
- **Tags:** `.tag-link`, `.tag-link-exists` (primary), `.tag-link-missing` (warning).

### T8. Modelo de página (4 tipos + custom por workspace)

- **Cuatro tipos built-in**: `note`, `reference`, `entity`, `concept`. Son los
  únicos valores de `Dran.PageRegistry.types/0`.
- **`meta.kind` NO existe.** Se fueron el select de kind, el filtro `?kind=`, la
  validación por kind y `kind_labels/0`. `meta.props` **se queda** (bolsa libre,
  con `PropsMaterializer`).
- **Tipos custom por workspace**: `workspaces.workspace_page_types` (jsonb, lista
  ordenada de `{slug, label, plural, path, icon, color, meta_fields}`). Los tipos
  efectivos = 4 built-in ∪ custom. El `path` es explícito y único.

**Reglas de UI que se derivan:**

- **El sidebar, la leyenda y los filtros iteran los tipos efectivos del
  workspace**, nunca `PageRegistry.types()` a secas: un tipo custom aparece con
  la misma dignidad que un built-in.
- **Sin cláusulas por tipo.** Un helper con una cláusula por slug está prohibido:
  un tipo custom nace sin cláusula y cae al fallback. El color viaja en el dato
  del tipo (`Workspace.page_type_color/2`), no en una tabla de casos.
- **La excepción son las relaciones, no los tipos.** Los tipos de relación son un
  conjunto cerrado del dominio, así que una tabla de casos por relación sí es
  legítima — hoy `PageComponents.relation_type_badge_class/1` (clases
  semánticas) y `GraphHelpers.edge_colors/0` (hex para el canvas). Deuda menor
  declarada: dos mapas para el mismo hecho, unificables en la paleta nombrada.
- **Iconos de tipo custom**: los `.hero-*` solo compilan si `app.css` los
  escanea. El `@source` debe cubrir el directorio del registry y cualquier
  icono elegible en el formulario de tipos custom.

### T9. Referencias (código real)

- `lib/dran_web/components/core_components.ex` — `flash`, `button`
  (`variant` primary/nil), `input`, `header` (título `text-title`, §T1),
  `table` (`table-sm`, stream), `list`, `icon`, `show`/`hide`,
  `translate_error(s)` y las primitivas compartidas `nav_link`, `nav_group`,
  `menu_item`, `section`, `modal`, `empty_state` (§C4).
- `lib/dran_web/components/layouts.ex` — shell `app/1`, `sidebar_nav`,
  `instance_nav`, `user_footer`, `flash_group`; el `nav_link` de la sidebar
  delega en el de `CoreComponents` (§C4).
- `lib/dran_web/components/layouts/root.html.heex` — `data-theme="dim"` y el
  banner de impersonación.
- `lib/dran_web/components/resource_components.ex` — `resource_modal` (§T3.1),
  `resource_header`, `form_actions`, `markdown_body_field`.
- `lib/dran_web/components/command_palette.ex` — `DranWeb.CommandPalette` (⌘K).
- `lib/dran_web/components/share_dialog.ex` — diálogo de compartición y el select
  nativo de referencia (§T4).
- `lib/dran/page_registry.ex` — 4 tipos built-in: `types/0`, `ui/1` (path,
  label, icon, color, plural) y `type_colors/0` (paleta nombrada).
- `lib/dran/workspace.ex` — tipos custom: `custom_page_types/1`, `page_type_ui/2`
  y los accesos `page_type_{path,label,plural,icon,color}`. Toda superficie que
  pinta un tipo pasa por acá (built-in ∪ custom).
- `lib/dran_web/graph_helpers.ex` — paleta nombrada (relaciones, neutro,
  ocultos) y `build_page_subgraph/2`.
- `lib/dran_web/live/journey_live.ex` — barras + sparkline (§T6).
- `lib/dran_web/live/search_live.ex` — resultados de búsqueda; chip/icono/badge
  del resultado toman el color del tipo.
- `assets/css/app.css` — tema `dim --default`, escala tipográfica, superficies,
  skeleton, lift, foco, regla global de tablas, TipTap, mermaid,
  wikilinks/tags/embeds. Inventario de CSS propio en §T1.
- `assets/js/hooks/graph_3d.js` — `cssColor()`/`oklchAlpha()` (vars del tema al
  canvas), paleta nombrada espejo, tooltip HTML con `textContent` (no
  `innerHTML`).
- Skills: `liveview-ui-wiring` (pickers), `phoenix-daisyui-theming` (tema).

### Verificar

```bash
grep -n 'data-theme' lib/dran_web/components/layouts/root.html.heex   # dim
grep -n 'themes:' assets/css/app.css                                   # dim --default
grep -rn '@apply' assets/css/ | grep -v 'sin @apply'                   # 0 (el único hit es el propio comentario)
grep -rnE 'type_chip_bg|type_icon_color|defp type_badge\b' lib/        # 0 (type_badge_label es legítimo: delega a ui_label)
grep -rn 'table-zebra' lib/                                            # 0
grep -rnE 'app_topbar|sidebar_footer_icons|workspace_selector' lib/    # 0 (shell topbar y selector de contexto eliminados)
grep -n 'p-4 pb-16 sm:p-6' lib/dran_web/components/layouts.ex          # padding mobile-first (§C3.1)
grep -c 'btn-soft' lib/dran_web/components/layouts.ex                  # 0 (el activo usa bg-primary/15)
mix tailwind dran && grep -c 'data-theme=dim' priv/static/assets/css/app.css  # 1
grep -n 'drawer lg:drawer-open' lib/dran_web/components/layouts.ex      # shell responsive
grep -c 'class="drawer lg:drawer-open[^"]*lg:grid-rows-1' lib/dran_web/components/layouts.ex  # 1 (fila acotada, §C12.5)
grep -n 'shell-hide' assets/css/app.css                                # colapso a rail (desktop)
grep -c '<.button' lib/dran_web/live/*.ex                               # CTAs de crear como componente
grep -rn 'flex-wrap items-center justify-between' lib/dran_web/live/   # headers que envuelven
grep -rn '^      workspaces={' lib/dran_web/live/*.ex                  # 0 (Layouts.app no tiene attr `workspaces`)
grep -c 'nav={:instance}' lib/dran_web/live/admin_groups_live.ex        # 1 (todo /admin/* lo lleva; sin él el nav cae al de conocimiento)
grep -c 'nav={:instance}' lib/dran_web/live/workspace_settings_live.ex  # 1 (/settings/instance es página de instancia)
grep -c 'href={~p"/admin/users"}' lib/dran_web/components/layouts.ex  # 2 (nav de instancia + grupo Admin del menú de perfil)
grep -rn 'admin/workspaces' lib/ | grep -v 'redirect'                    # 0 (/admin/workspaces murió en W6)
grep -rnE 'is_default|personal_workspace_id|can_create_workspaces' lib/   # 0 (columnas y flag retirados en W6)
grep -rn 'user-menu a\[href' test/dran_web/live/instance_shell_test.exs # el grupo Admin del menú está pinchado
grep -rn 'p-4 sm:p-6' lib/dran_web/                                    # padding mobile-first
grep -c 'for="sidebar-collapse"' lib/dran_web/components/layouts.ex     # 1 (toggle único, en la barra)
grep -c 'aside[^>]*label for="sidebar' lib/dran_web/components/layouts.ex  # 0 (el sidebar no lleva toggle propio)
grep -n 'user-menu' assets/css/app.css                                  # el menú del rail abre a la derecha
grep -n '^## C12' DESIGN.md                                            # shell en Commons
grep -n '^## Custom' DESIGN.md                                          # sólo lo exclusivo de Dran
bash ../boilerplate/skeleton/check-commons.sh .                        # Commons byte-exacto
```