defmodule Dran.Repo.Migrations.DropSystemFromSkills do
  @moduledoc """
  Retira el catálogo de SISTEMA de skills: la suite (el router y los ocho flows)
  ya no se sirve por la instancia — vive CON el plugin de Hermes
  (`hermes_plugin/dran/skills/<slug>/SKILL.md`, filas locales `dran:<slug>`).

  Dos cosas, en este orden:

  1. PODA las filas `system: true` que el boot reconciliaba (contenido de código,
     no datos de nadie: nadie las escribió desde la web ni desde el API). Sin
     esto, la tabla seguiría sirviendo 9 filas que el código ya no mantiene.
  2. Retira la columna y su índice parcial: sin sincronizador, `system` no tiene
     quién la escriba (toda fila queda en `false`) y su única query —la que
     filtraba el conjunto de sistema— desapareció con el subsistema.

  `down` vuelve a crear la columna y el índice, pero NO restaura las 9 filas: su
  contenido ya no se hornea en el release (era lo que hacía `Dran.Skills.Builtin`
  al compilar), así que la suite no se puede re-servir desde acá. Revertir el
  esquema no alcanza: para volver atrás hay que traer el subsistema y redeployar.
  """
  use Ecto.Migration

  def up do
    execute("DELETE FROM skills WHERE system")

    execute("DROP INDEX IF EXISTS skills_system_index")

    alter table(:skills) do
      remove :system
    end
  end

  def down do
    alter table(:skills) do
      add :system, :boolean, default: false, null: false
    end

    create index(:skills, [:system], where: "system", name: :skills_system_index)
  end
end
