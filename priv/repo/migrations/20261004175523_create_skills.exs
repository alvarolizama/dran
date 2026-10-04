defmodule Dran.Repo.Migrations.CreateSkills do
  @moduledoc """
  El skill como ENTIDAD de primera clase: tabla `skills` con dueño y visibilidad,
  igual que `goals` y `plans`.

  Un skill son INSTRUCCIONES para un agente conectado por API, no contenido de
  lectura: por eso no es una página (no entra al grafo, a la búsqueda semántica
  ni a los workers) y su identificador **no es renombrable** — el `slug` es la
  dirección del wire (`^[a-z][a-z0-9_-]*$`) y renombrarlo rompe a quien lo tenga
  cargado.

  ## Convenciones

  * `visibility` default `private` con `owner_user_id` (`on_delete: nilify_all`):
    la lectura pasa por `Dran.ContentVisibility.filter(scope, :skill)` en el
    punto único.
  * `slug` único por dueño con `COALESCE(owner_user_id, 0)`: los NULL son
    distintos en un índice único, así que el contenido de sistema (dueño NULL)
    comparte un solo balde — la misma semántica que goals y planes.
  * `version` + `content_hash` monotónicos: el hash es del CUERPO y es lo que
    sostiene el `unchanged` que evita re-inyectar el skill en cada turno.
  * `body` (markdown) y `description`: la descripción es el ÚNICO texto que el
    agente ve en el índice del prompt, así que se valida al guardar (≤ 60) y
    nunca se trunca al servir.
  """

  use Ecto.Migration

  def change do
    create table(:skills, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      # La dirección del wire: inmutable y única por dueño.
      add :slug, :string, null: false
      # El `name` del frontmatter del SKILL.md montado.
      add :name, :string, null: false
      add :description, :string, null: false
      add :body, :text, default: "", null: false

      add :version, :integer, default: 1, null: false
      add :content_hash, :string, null: false

      add :visibility, :string, default: "private", null: false
      add :owner_user_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:skills, ["COALESCE(owner_user_id, 0)", :slug],
             name: :skills_owner_user_id_slug_index,
             unique: true
           )

    create index(:skills, [:owner_user_id])
    create index(:skills, [:visibility], where: "visibility = 'public'")
  end
end
