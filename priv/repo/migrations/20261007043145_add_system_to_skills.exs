defmodule Dran.Repo.Migrations.AddSystemToSkills do
  @moduledoc """
  El marcador de los skills de SISTEMA: las instrucciones que Dran sirve por
  default a TODA credencial (cuenta, grupo o admin legacy), sin share y sin
  depender de su `visibility`.

  Por qué una columna propia y no "dueño NULL":

  * `owner_user_id` NULL ya significa "contenido de sistema/instancia" en goals
    y planes, pero el token admin LEGACY también escribe con dueño NULL (no
    tiene fila de usuario). Marcar por `IS NULL` convertiría esos skills en
    built-ins de sólo lectura: una regresión silenciosa en vez de un default.
  * Este flag es EXPLÍCITO y lo escribe sólo el sincronizador de código
    (`Dran.Skills.Builtin`) — ninguna credencial lo declara desde el body.

  El índice parcial existe porque el sincronizador resuelve SU conjunto por
  `system` en cada boot: es la única query que filtra por esta columna.
  """

  use Ecto.Migration

  def change do
    alter table(:skills) do
      add :system, :boolean, default: false, null: false
    end

    create index(:skills, [:system], where: "system", name: :skills_system_index)
  end
end
