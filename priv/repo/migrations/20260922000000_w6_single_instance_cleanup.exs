defmodule Dran.Repo.Migrations.W6SingleInstanceCleanup do
  @moduledoc """
  W6 (contrato `instance-visibility-20260919`, D1/D3/D4): el cierre destructivo
  del modelo multi-workspace — el que la ola W6 declaró y no ejecutó.

  W1 (`InstanceSingleWorkspace`) ya PLEGÓ el contenido en un superviviente y
  dejó las filas plegadas "inert until W6 (D3)". Esto es ese W6:

  1. Repunta lo que aún apunte a otra workspace (una base que no pasó por el fold
     de W1, o que creció entre medias) y luego BORRA las filas plegadas. El
     contenido no se pierde: se absorbe en la instancia, y los choques de índice
     único se resuelven por duplicado REAL (mismo `slug` / `content_hash` /
     `cluster_id`), donde la copia de la instancia es la que gana.
  2. Tira las columnas que con un solo contenedor ya no significan nada:
     `workspaces.is_default` (el flag exclusivo que elegía entre varios) y, en
     `users`, `personal_workspace_id`, `default_workspace_slug` y
     `can_create_workspaces` (el "workspace personal por cuenta" y el permiso de
     crear más contenedores).

  Lo que NO se tira, y es deliberado: la tabla `workspaces` SOBREVIVE como
  portadora de los settings de instancia —una fila con `workspace_page_types` y
  los thresholds— (D3), y `user_workspaces` / `api_key_workspaces` siguen ahí:
  su retirada quedó fuera del alcance de esta ola por decisión explícita.

  ## Tolerante al esquema real, no al que uno supone

  Cada paso se decide contra `information_schema`, no contra una creencia. Dos
  bases reales lo exigen: `settings` NO tiene `workspace_id` en el esquema de las
  migraciones (`create_settings` define `key` como PK, un solo valor por clave en
  la instancia), pero hay bases con esa columna añadida fuera de banda —una
  migración aplicada que nunca llegó al repo—. Si está, se absorbe y se TIRA
  (es drift: la clave es la identidad de esa tabla); si no está, ni se menciona.

  Corre dentro de la transacción de Ecto: o la instancia queda limpia o no
  cambia nada.
  """
  use Ecto.Migration
  import Ecto.Query

  # Las que SIEMPRE llevan `workspace_id` (se comprueba igual: el coste es una
  # consulta a information_schema por tabla y evita un fallo en producción por
  # una columna que en alguna base no existe).
  @child_tables ~w(knowledge_pages memories collections reports brain_log
                   cluster_summaries worker_sessions user_workspaces
                   api_key_workspaces)

  # Tablas donde un choque de índice único significa "la misma página/colección/
  # informe con el mismo slug": se le re-sufija el slug para no perderla.
  @slug_tables ~w(knowledge_pages collections reports)

  def up do
    case survivor_id() do
      nil -> :ok
      survivor_id -> absorb_and_delete_the_rest(survivor_id)
    end

    # Primero los índices del flag, después las columnas (Postgres se los
    # llevaría por delante con ellas; nombrarlos deja el drop legible).
    execute "DROP INDEX IF EXISTS workspaces_is_default_index"
    execute "DROP INDEX IF EXISTS users_personal_workspace_id_index"

    alter table(:workspaces) do
      remove :is_default
    end

    alter table(:users) do
      remove :personal_workspace_id
      remove :default_workspace_slug
      remove :can_create_workspaces
    end
  end

  def down do
    # Las COLUMNAS vuelven (con sus defaults); los DATOS de las filas plegadas
    # no: en cuanto se repuntaron, qué fila pertenecía a qué contenedor se
    # perdió. Des-plegar es un restore desde backup.
    alter table(:users) do
      add :personal_workspace_id, :binary_id
      add :default_workspace_slug, :string
      add :can_create_workspaces, :boolean, default: false, null: false
    end

    alter table(:workspaces) do
      add :is_default, :boolean, default: false, null: false
    end

    create unique_index(:workspaces, [:is_default],
             where: "is_default = true",
             name: :workspaces_is_default_index
           )
  end

  # La que conserva su fila: el default marcado (la elección que W1 dejó), si no
  # la más antigua — la MISMA regla que usó el fold de W1, para que ambas
  # migraciones coincidan en cualquier base.
  defp survivor_id do
    case repo().one(
           from(w in "workspaces",
             select: w.id,
             order_by: [desc: w.is_default, asc: w.inserted_at, asc: w.id],
             limit: 1
           )
         ) do
      nil -> nil
      id -> Ecto.UUID.cast!(id)
    end
  end

  defp absorb_and_delete_the_rest(survivor_id) do
    s = to_string(survivor_id)

    # Solo las tablas que realmente tienen la columna; y `settings` (que puede
    # tenerla por drift) entra en la lista si la tiene.
    tables = Enum.filter(@child_tables, &has_column?(&1, "workspace_id"))
    drifted_settings? = has_column?("settings", "workspace_id")

    if drifted_settings? do
      # `key` es la PK de `settings`: si la instancia ya tiene ese valor, el de
      # la fila plegada es el mismo setting con otro contenido y gana el de la
      # instancia.
      execute """
      DELETE FROM settings loser
      WHERE loser.workspace_id IS NOT NULL
        AND loser.workspace_id <> '#{s}'
        AND EXISTS (
          SELECT 1 FROM settings keeper
          WHERE keeper.workspace_id = '#{s}' AND keeper.key = loser.key
        )
      """
    end

    # `user_workspaces` / `api_key_workspaces`: único (user_id|api_key_id,
    # workspace_id). Basta una fila por usuario/key ya en la instancia: el rol
    # vive en `users.instance_role` desde W1 y el alcance de la key se conserva
    # con la fila que sobrevive (misma key, mismo nivel).
    for {table, owner_col} <- [
          {"user_workspaces", "user_id"},
          {"api_key_workspaces", "api_key_id"}
        ],
        table in tables do
      execute """
      DELETE FROM #{table} loser
      WHERE loser.workspace_id <> '#{s}'
        AND EXISTS (
          SELECT 1 FROM #{table} keeper
          WHERE keeper.workspace_id = '#{s}' AND keeper.#{owner_col} = loser.#{owner_col}
        )
      """
    end

    # El choque es el MISMO hecho (mismo content_hash) o los resúmenes del mismo
    # cluster escritos en dos contenedores: un duplicado no es contenido perdido.
    if "memories" in tables do
      execute """
      DELETE FROM memories loser
      WHERE loser.workspace_id <> '#{s}'
        AND EXISTS (
          SELECT 1 FROM memories keeper
          WHERE keeper.workspace_id = '#{s}'
            AND keeper.content_hash = loser.content_hash
            AND keeper.owner_user_id IS NOT DISTINCT FROM loser.owner_user_id
        )
      """
    end

    if "cluster_summaries" in tables do
      execute """
      DELETE FROM cluster_summaries loser
      WHERE loser.workspace_id <> '#{s}'
        AND EXISTS (
          SELECT 1 FROM cluster_summaries keeper
          WHERE keeper.workspace_id = '#{s}' AND keeper.cluster_id = loser.cluster_id
        )
      """
    end

    # Un slug repetido en la instancia NO es un duplicado: es otra página con el
    # mismo nombre. Se re-sufija (como hizo el fold de W1) para no perderla — el
    # índice único [workspace_id, slug] rechazaría el UPDATE.
    for table <- Enum.filter(@slug_tables, &(&1 in tables)) do
      execute """
      UPDATE #{table} loser
      SET slug = loser.slug || '-' || left(md5(random()::text), 6)
      WHERE loser.workspace_id <> '#{s}'
        AND EXISTS (
          SELECT 1 FROM #{table} keeper
          WHERE keeper.workspace_id = '#{s}' AND keeper.slug = loser.slug
        )
      """
    end

    # Ahora sí: todo lo que quede apuntando fuera, entra.
    for table <- tables ++ if(drifted_settings?, do: ["settings"], else: []) do
      execute """
      UPDATE #{table}
      SET workspace_id = '#{s}'
      WHERE workspace_id IS NOT NULL AND workspace_id <> '#{s}'
      """
    end

    # Las filas plegadas dejan de existir: ya no las referencia nadie.
    execute """
    DELETE FROM workspaces WHERE id <> '#{s}'
    """

    # Y el drift de `settings` se tira: con `key` como PK, una columna de
    # workspace no significa nada (y su índice único, redundante, se va con ella).
    if drifted_settings? do
      execute "ALTER TABLE settings DROP COLUMN IF EXISTS workspace_id"
    end
  end

  defp has_column?(table, column) do
    %{rows: rows} =
      repo().query!(
        """
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = $1 AND column_name = $2
        """,
        [table, column]
      )

    rows != []
  end
end
