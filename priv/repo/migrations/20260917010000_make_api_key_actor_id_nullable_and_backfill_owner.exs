defmodule Dran.Repo.Migrations.MakeApiKeyActorIdNullableAndBackfillOwner do
  use Ecto.Migration

  @moduledoc """
  W3 — tiempo M1 de la migración de actores en tres tiempos (M10).

  ## Qué hace (SOLO tiempo M1)

  1. `api_keys.actor_id` pasa a **nullable**: un API key ya no está atado a
     un actor (crear una key deja de crear una fila en `actors`).
  2. **Backfill** de `api_keys.created_by_user_id` desde
     `actors.owner_user_id`: para las keys históricas cuyo key-actor tenía
     dueño y cuya key no tenía creador registrado, el dueño del actor se
     convierte en el dueño de la key (así `owner_user_id` de lo escrito,
     resuelto desde `api_keys.created_by_user_id`, sigue siendo correcto
     aunque el actor ya no participe en la cadena de autenticación).

  ## Qué NO hace (tiempos M2/M3, deliberadamente fuera de W3)

  * **NO** hace `DROP COLUMN actor_id`. El tiempo M3 queda pendiente de la
    decisión ?03 (¿se borran los actores `kind: "agent"`?) y de un deploy
    que ya no lea la columna. Hasta entonces la columna se mantiene
    nullable y el código deja de escribirla/leerla — es decir, las filas
    nuevas la dejan en `NULL`.
  * **NO** toca `actors` ni `Actor.@kinds` (constraint 8: `"agent"` se
    conserva porque hay filas históricas y quitar el valor del changeset
    rompería casts sobre ellas).

  El código companion (W3) resuelve la atribución server-side así:
  `created_by` = header `X-Hermes-Agent` si viene, si no el `name` de la
  key; `owner_user_id` = `api_keys.created_by_user_id`.
  """

  def up do
    alter table(:api_keys) do
      modify :actor_id, :binary_id, null: true
    end

    # Backfill: el dueño del key-actor hereda como creador de la key cuando
    # la key aún no tenía creador. Solo rellena NULLs (`IS NULL`), nunca
    # pisa un `created_by_user_id` ya establecido.
    execute("""
    UPDATE api_keys k
       SET created_by_user_id = a.owner_user_id
      FROM actors a
     WHERE k.actor_id = a.id
       AND k.created_by_user_id IS NULL
       AND a.owner_user_id IS NOT NULL
    """)
  end

  def down do
    # Reversible mientras la columna siga existiendo: vuelve a NOT NULL.
    # (Fallará si ya hay filas con actor_id NULL — correcto: exige resolver
    # esas filas a mano antes de revertir.)
    alter table(:api_keys) do
      modify :actor_id, :binary_id, null: false
    end
  end
end
