---
name: dran-dev-settings-config
description: "Use when editing Dran settings-backed config."
---

# Dran settings-backed configuration

Dran instance/runtime config lives in the `settings` table via
`Dran.Settings.get/put/delete`; the `@defaults` map supplies fallbacks.
Models, tuning thresholds and the legacy admin API token follow this
pattern. Env vars remain ONLY for boot-critical
config (DATABASE_URL, secrets, inference endpoint, uploads, workers) — do
not reintroduce env-var reads for instance config, and do not migrate
boot-critical ones into the DB.

The **default workspace is not a setting**: it is the `is_default` flag on a
workspace row, set from `/admin/workspaces` and read by
`Dran.Knowledge.get_default_workspace/0`. Never reintroduce env vars or
settings keys (`default_workspace_slug` / `default_workspace_name`, removed)
for it; the readers fall back to the only-workspace rule and then the
`"personal"` literal. Per-user landing is
`Dran.Accounts.session_workspace_slug/1`.

## Adding an editable setting

1. Reader module functions (e.g. `Dran.Auth`): read the setting, fall back
   to the default, and **rescue DB errors to the safe fallback** — these
   readers are called during boot, release `eval` and job contexts where
   the repo may not be started. For secrets fail CLOSED: an unreadable
   token resolves to nil/disabled, never a compiled-in default.
2. Admin UI: form on `/admin/system` (AdminSystemLive) built with
   `to_form(%{...}, as: :instance)` from current setting values at mount,
   `<.input field={@form[:key]}>` fields, save handler writes each key.
3. **Empty input on an optional setting must call `Settings.delete(key)`** —
   skipping the write leaves the stale value live while the UI shows
   empty. A test that pre-sets the value BEFORE mount and then submits the
   field cleared catches this; one that only tests the set path does not.
4. When the setting gates boot-time behavior (auto-creating the default
   workspace in release setup/seeds), gate it on a `..._configured?`
   reader and keep release/seeds reading it at runtime — a deleted
   workspace stays deleted when no override is set.
5. Slug-type values are URL identifiers: validate `^[a-z0-9]+(-[a-z0-9]+)*$`
   server-side and reject with a flash before writing anything.

## Retiring a setting

Removing a setting is a sweep, not a delete: a leftover read keeps the old
value alive behind the UI. Touch all of it in one change:

1. Every reader (e.g. `Dran.Auth`) — the resolution chain, its `@doc` and the
   module `@moduledoc`; grep the key name repo-wide afterwards.
2. The admin UI control AND its assigns/moduledoc, plus any `..._configured?`
   gate that the removed overlay fed.
3. The docs that name the old home: README, `.env.example`, `priv/repo/seeds.exs`,
   the `dran`/`dran-dev-*` skills.
4. Gettext: `mix gettext.extract --merge` drops the obsolete msgids — then fix
   `scripts/fill_es_gettext.py` (add the new strings, delete the dead keys) and
   re-run it, or the Spanish catalog ships an empty msgstr.
5. A regression test that PRE-SETS the retired key and asserts the new behavior
   (the value is ignored, not merely unwritten) — otherwise a lingering read
   passes every test that only exercises the set path.
6. When the control moves to another page, move its explanation with it: the
   helper text under the new control, not deleted with the old panel.

## Verification

- Settings are plain rows: LiveView tests assert directly on
  `Dran.Settings.get/1` after `render_submit` — no stubbing needed.
- Test modules do not import `gettext/1`; use the file's `t/1` helper.
- Do not verify by logging into the user's running instance — the owner
  password is unknown and stays unknown; prove config changes with tests
  plus `PORT=<free> mix run -e` runtime checks (port rule in
  dran-inference-providers).
- Instance monitoring widgets (DB size, disk, BEAM memory, uptime):
  `references/monitoring-widgets.md`.
