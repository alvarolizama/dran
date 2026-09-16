---
name: dran-dev-settings-config
description: "Use when editing Dran settings-backed config."
---

# Dran settings-backed configuration

Dran instance/runtime config lives in the `settings` table via
`Dran.Settings.get/put/delete`; the `@defaults` map supplies fallbacks.
Models, tuning thresholds, the legacy admin API token and the default
workspace all follow this pattern. Env vars remain ONLY for boot-critical
config (DATABASE_URL, secrets, inference endpoint, uploads, workers) — do
not reintroduce env-var reads for instance config, and do not migrate
boot-critical ones into the DB.

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
