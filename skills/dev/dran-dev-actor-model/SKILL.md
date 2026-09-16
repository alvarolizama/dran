---
name: dran-dev-actor-model
description: "Use when changing Dran identity/ownership code."
---

# dran-dev-actor-model — Identity, ownership, and attribution in Dran

Dran separates three things that "ownership" questions conflate: the
IDENTITY (actor), the CREDENTIAL (api key), and the PERMISSION (workspace
role / access level). Answer by naming which layer the word "owner"
actually points at. Users do NOT own agents — actors are global
identities; only the API key carries a creator.

## The model (verify against schema + migrations, not docs)

- `actors` — global identity registry, NOT workspace-scoped and NOT owned
  by anyone. Fields: `name` (the join key), `kind`, `display_name`,
  `host`. Kinds: `user | agent | system`.
- `users.actor_id` — every human is an actor (`kind: user`, backfilled
  from email). A user IS an actor; a user does not own other actors.
- `api_keys.actor_id` — the actor this key is a credential FOR
  (`kind: agent` normally). The key name IS the agent identity by
  convention (`ApiKey.ensure_actor_for_key_name/1` creates the actor on
  first sight), so agent↔key is effectively 1:1.
- `api_keys.created_by_user_id` — the human who created the key. This is
  the ONLY user→agent edge in the system, and it lives on the key, never
  on the actor.
- Permissions never live on the actor: `api_key_workspaces.access_level`
  (read|write) for keys, `user_workspaces.role` for humans.
- Attribution (`created_by` strings on pages/memories) is server-side
  only, resolved from the acting identity to `Actor.name`
  (`Dran.Auth.resolve_created_by/1`) — never client-settable.
- System actors (`system`, `entity_linker`, `jobs`, `automation`) are
  code-managed: `ensure_system_actors!/0` upserts them idempotently on
  boot/migration; CRUD refuses `kind: "system"` on create, update,
  delete.

## Answering an ownership / permission question

1. Name the layer first: identity (who did it), credential (what token),
   permission (which workspace, which level). Most "does user X own agent
   Y" questions are really about the key's creator or a workspace role.
2. Confirm the column EXISTS before reasoning about it. Ownership columns
   are the codebase's fossil layer: `pages.owner` and `tasks.owner` were
   DROPPED (they duplicated `created_by`). Grep migrations, not just
   `lib/`.
3. Find the ENFORCEMENT point, not the naming. Agents tab: any
   authenticated user can list/create/update/delete agent actors
   (`/settings/agents` is `[:browser, :auth]`, `list_managed_actors/0`
   has no per-user scoping). Keys: `owned_api_key/2` in SettingsLive
   allows the creator or an instance owner only.
4. Answer with `path:line` evidence per claim — this user wants the
   verified chain across schema, migration, and enforcement point, not a
   paraphrase of the docs.

## Pitfalls

- **Do not trust tool schema text for attribution fields.** The
  input schemas still advertise an `owner` parameter while the column was
  dropped; verify any field claim against the Ecto schema + migrations
  before repeating it.
- **`owner` and `created_by` are not interchangeable historically.** Live
  writes use `created_by`; pre-actor rows carry `owner` values, and legacy
  attributions (`"admin"`, historical usernames) resolve through the
  legacy-token branch in `Dran.Auth` and backfilled `kind: agent` actors.
- **The synthetic API-key identity map is not a User struct**: it carries
  `:key_name`, `:actor`, `:access_levels`. Code that reads `user.email` /
  `user.id` on API-key requests mis-resolves attribution — go through
  `Dran.Auth.resolve_created_by/1`.
- **`GET /api/agent/config` is agent-key-only** (404 for user tokens and
  the legacy admin token): not a debugging tool for user-identity auth.
- **`delete_actor` guards are deliberate**: an actor with API keys or one
  that is a user's identity actor is refused (`:actor_has_api_keys`,
  `:actor_is_user_identity`); `attribution_count/1` previews pages +
  memories before the confirm dialog.

Legacy columns, backfills and fallback rules: `references/attribution-legacy.md`.
