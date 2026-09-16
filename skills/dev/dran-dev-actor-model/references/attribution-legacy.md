# Attribution legacy layers (Dran)

Only needed when touching historical rows, attribution bugs, or the
identity backfill migrations. The current model is in SKILL.md.

## Dropped / superseded columns

- `pages.owner`, `tasks.owner` — dropped; `created_by` is the single
  attribution column now (server-side from the actor).
- `tasks.assignee_actor_id` — preferred over the old `assignee_id`
  (users-only); the old column is kept nullable for history.
- `goals.created_by` / `updated_by` — added when goals had no attribution
  at all. (goals/workflows were later dropped entirely; treat any
  remaining reference as stale.)

## Backfills (run once, idempotent by convention)

- `api_keys.actor_id` — one `kind: agent` actor per key NAME; the name is
  the join key with historical data.
- `users.actor_id` — one `kind: user` actor per email.
- Historical `pages.created_by` values — registered as `kind: agent`
  actors so old rows resolve, even for values that look human (they came
  from token-based producers).
- System actors are seeded in the migration AND re-upserted on boot
  (`ensure_system_actors!/0`), so they survive restores.

## Fallback chain in Dran.Auth

`actor_name(user)` prefers the synthetic map's `:actor`, falls back to
`:key_name`. For web users: email. Special cases: the legacy `"admin"`
email resolves to `"system"` for owner and `"admin"` for created_by;
no identity at all resolves to `"system"`.

## Legacy admin bearer

`Dran.Settings` key `"api_token"` — full owner, no user row, no actor.
Its attribution lands on `"system"`/`"admin"`. Unset means disabled
(fail closed). Rotate from `/admin/system`.
