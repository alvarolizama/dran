---
name: dran-dev-actor-model
description: "Use when changing Dran identity/ownership code."
---

# dran-dev-actor-model — Identity, ownership, and attribution in Dran

Dran separates three things that "ownership" questions conflate: the
IDENTITY (who wrote it), the CREDENTIAL (API key), and the PERMISSION
(workspace role / access level). Answer by naming which layer the word
"owner" actually points at.

**An API key creates NO actor.** The actor model for keys is gone (W3/M5):
the key IS its own agent identity. Attribution is derived server-side from the
key and the `X-Hermes-Agent` header — never client-settable.

| Layer | API key | User token |
|---|---|---|
| identity | key `name` + `X-Hermes-Agent` header | the user row |
| permission | `api_key_workspaces.access_level` | `user_workspaces.role` |
| created_by | header, else key name | email |
| owner_user_id | `api_keys.created_by_user_id` (key creator) | the user |

## The model (verify against schema + migrations, not docs)

- `actors` — global identity registry, NOT workspace-scoped and NOT owned
  by anyone. Fields: `name` (the join key), `kind`, `display_name`,
  `host`. Kinds: `user | agent | system`.
- `users.actor_id` — every human is an actor (`kind: user`, backfilled
  from email). A user IS an actor; a user does not own other actors.
- `api_keys.actor_id` — **nullable, no longer written** for new keys; a key
  does not create or bind an actor. Existing non-null values are historical.
  `ensure_actor_for_key_name/1` is gone — do not reintroduce it.
- `api_keys.created_by_user_id` — the human who created the key. This is the
  ONLY user→agent edge in the system, and it lives on the key.
- Permissions never live on an actor: `api_key_workspaces.access_level`
  (read|write) for keys, `user_workspaces.role` for humans.
- Attribution (`created_by` strings on pages/memories) is server-side only
  (`Dran.Auth`), never client-settable:
  - API key requests: the synthetic map built in ONE place,
    `DranWeb.Router.require_api_token/2` (router.ex:275-290), carries
    `:key_name`, `:agent_name` (the header), `:actor` (id/name derived from
    the key, kept for pre-change consumers), `:created_by_user_id` and
    `:owner_user_id` (both = `api_keys.created_by_user_id`).
  - `resolve_created_by/1` = `:agent_name` → `:key_name` → email (`"admin"`
    email → `"admin"`); `resolve_owner_user_id/1` = `:created_by_user_id`
    (nil for keys with no creator).
  - The header is attribution, NOT authorization: it never widens access.
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
3. Find the ENFORCEMENT point, not the naming. **`/settings/api-keys`**
   (`SettingsLive`, renamed from `/settings/agents`) has NO actor CRUD: any
   logged-in user lists/manages ONLY their own keys, enforced per-key by
   `owned_api_key/2`. `Dran.Actors` still owns `kind: user` / `kind: system`
   actors and keeps its CRUD functions (`list_managed_actors/0` has no
   per-user scoping and no live UI caller any more — do not wire it to a
   browser-facing surface without an authorization review).
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
  `:key_name`, `:agent_name`, `:actor`, `:access_levels`, `:workspaces`,
  `:created_by_user_id`, `:owner_user_id`. Code that reads `user.email` /
  `user.id` on API-key requests mis-resolves attribution — go through
  `Dran.Auth.resolve_created_by/1` / `resolve_owner_user_id/1`.
- **Do not add an actor back for keys.** The ownership clauses of
  `ContentVisibility.scope/3` match on `:owner_user_id`, not on
  `%Actor{owner_user_id: …}` — a key with no actor must still scope correctly.
  Verify with a test that reads back a page written by a key.
- **`GET /api/agent/config` is agent-key-only** (404 for user tokens and
  the legacy admin token): not a debugging tool for user-identity auth.
- **`delete_actor` guards are deliberate**: an actor with API keys or one
  that is a user's identity actor is refused (`:actor_has_api_keys`,
  `:actor_is_user_identity`). `attribution_count/1` previews pages +
  memories. Since the key no longer creates actors, historical
  `kind: agent` rows are the main things those guards still protect.
- **`users.actor_id` no lo escribe ningún cast.** `User.changeset/2` NO castea
  `:actor_id`, así que meterlo en los attrs (`Map.put(attrs, :actor_id, …)`) se
  descarta SIN aviso: la fila en `actors` se creaba y el vínculo quedaba NULL.
  Como solo la migración `20260901062734` backfilleó las filas de su momento, el
  guard `:actor_is_user_identity` de `delete_actor/1` no veía la identidad de
  ninguna cuenta nueva. Va con `put_change/3` post-changeset, en
  `Accounts.insert_user/2` (el único camino de inserción de cuentas, compartido
  por los dos `create_user*`). Antes de razonar sobre ese guard:
  `select count(*), count(actor_id) from users`.
- **Mismo mecanismo, credenciales: `User.changeset/2` tampoco castea `:password`.**
  `create_user/1` construye la fila y tira el password que le pasen → cuenta sin
  `password_hash` y sin `google_id`, o sea sin entrada (`authenticate_user/2` la
  rechaza siempre), y una invitación a un workspace que no lleva a ninguna parte.
  Para una persona va `create_user_with_password/1` (`registration_changeset`:
  email con formato, 8 mínimo, hash bcrypt). `create_user/1` es solo el alta de
  Google, donde el acceso lo da `google_id`.

## Cuentas: quién agrega a quién y quién resetea una contraseña

- No hay invitaciones por correo y no las hay sin montar el envío: `Dran.Mailer`
  existe (Swoosh, adapter `Local` en config, `Test` en test) y **no tiene un solo
  llamador** en `lib/`. Agregar gente es meter una cuenta que YA existe:
  `add_member_by_email/3` busca por email (case-insensitive) y responde
  `{:error, :user_not_found}` si no la hay.
- Puertas del alta de miembros (todas en la ruta, no en el handler):
  `/:ws/settings` pasa por `:workspace_admin` = dueño de la instancia (sesión
  `is_owner`) ∪ rol `owner`/`admin` de ESE workspace; el CREADOR queda con rol
  `owner` por `insert_owner_membership/2` (`knowledge.ex:145-166`). Un `editor`
  trabaja dentro del workspace pero no entra a configuración.
- El RESET de la contraseña de otra cuenta vive en `/admin/users` (scope `:admin`
  = dueño de instancia) porque poder cambiarla es poder entrar como esa persona:
  privilegio de instancia, no de workspace. `Accounts.update_user_as_admin/2` +
  `User.admin_changeset/2`, SIN `current_password` (el admin no la conoce: ese es
  el punto) y con un solo `Repo.update` por submit — si la contraseña no valida,
  el nombre tampoco se guarda.
- **Un input de contraseña vacío llega como `""`, y para el cast `""` NO es "sin
  cambio".** Sin sacarlo de `changes` (`delete_change/2`), `validate_length` lo
  rechaza y `put_password_hash/1` guarda el hash de la cadena vacía. En el mismo
  changeset: quitar el blanco, DESPUÉS validar el mínimo, DESPUÉS hashear.
- **El alta de una PERSONA exige NOMBRE** (`User.registration_changeset/2`:
  email + name + password), y el nombre no es decorativo: es lo que nombra su
  workspace personal. `personal_workspace_name/1` = el nombre, o `"Personal"` si
  no lo hay — **nunca la parte del correo**, que es lo que hacía antes
  (`nekrox@gmail.com` → "Nekrox" en `/nekrox`, o sea el correo eligiendo la URL).
  `/setup` y el modal de /admin/users lo piden obligatorio; `create_user/1` (el
  camino de Google/API) no lo exige, así que puede haber cuentas sin nombre y su
  personal se llama "Personal". Ojo: el slug SALE del nombre
  (`Slug.inject_create(field: "name")`) y renombrar el workspace NO lo cambia.
- **La autoría se guarda como identificador y se PINTA como nombre.** La columna
  `created_by` sigue llevando el correo del usuario (o el nombre de la key)
  porque es la clave de unión y lo que devuelve la API; lo que ve el usuario lo
  resuelve la vista con `Dran.Actors.creator_labels/1` (+ `creator_label/2`) en
  DOS queries por lote — un lookup por fila dentro de una tarjeta es el N+1 que
  esa función existe para evitar. Precedencia: nombre del usuario →
  `display_name` del actor → el identificador. No "arregles" lo que se ve
  cambiando la columna.

Legacy columns, backfills and fallback rules: `references/attribution-legacy.md`.
