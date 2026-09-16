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

`localhost` isn't reachable from the browser tool, and the seeded admin
login (`admin`/`dran`) may not match the dev DB, so don't try to curl the
live page. Verify a render by writing a THROWAWAY ConnCase test, running
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
