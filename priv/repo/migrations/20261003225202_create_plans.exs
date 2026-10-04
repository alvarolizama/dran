defmodule Dran.Repo.Migrations.CreatePlans do
  @moduledoc """
  El plan como ENTIDAD de primera clase: tabla `plans` con dueño y visibilidad,
  igual que `goals`.

  Decisión del owner (2026-10-03, contrato de superficies): el plan NO es un tipo
  de página — ni built-in ni declarado por instancia en `workspace_page_types` —
  y el checklist NO es una tabla. La medición que cerró la decisión: en `dran_dev`
  `workspace_page_types` es `[]` y las 8 páginas son `note`/`concept`, así que el
  único lugar donde el tipo `plan` existía era un fixture de test.

  Esto REVISA la Constraint 16 del contrato cerrado («no se crea tabla `plans`»),
  que queda como historia. Lo que NO se restaura es `steps`
  (`20260903231528_create_plans_steps.exs`): los pasos son el checklist jsonb
  `[%{"text" => _, "done" => _}]` del contenedor, la misma forma que la task.

  ## Convenciones

  * `id binary_id` con `gen_random_uuid()`, como goals/tasks (instancia única:
    sin `workspace_id`).
  * `visibility` default `private` (Constraint 2) + `owner_user_id` (Constraint 3):
    la lectura pasa por `Dran.ContentVisibility.filter/3` (Constraint 1).
  * `checklist` jsonb default `[]` (Constraint 8) y `lock_version` para el bloqueo
    optimista de la reescritura del checklist (el RMW del `toggle`).
  * Sin `goal_id`: el plan no cuelga de un goal. El vínculo, si existe, es una
    arista de `relations` (`plan` entra como node type).
  * Slug único por dueño con `COALESCE(owner_user_id, 0)`: los NULL son distintos
    en un índice único, y el contenido de sistema (dueño NULL) comparte un solo
    balde — la misma semántica que el predicado `taken?` de la app.
  """

  use Ecto.Migration

  def up do
    create table(:plans, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :title, :string, null: false
      add :slug, :string, null: false
      add :summary, :string
      add :body, :text, default: ""

      add :status, :string, default: "draft", null: false
      add :starts_on, :date
      add :due_on, :date

      # Los pasos: array ordenado en el jsonb del contenedor, nunca una fila.
      add :checklist, :jsonb, default: "[]", null: false

      # Bloqueo optimista del RMW del checklist (mismo trato que la task).
      add :lock_version, :integer, default: 1, null: false

      # Visibilidad por ítem, default privado (Constraints 2 y 3).
      add :visibility, :string, default: "private", null: false
      add :owner_user_id, references(:users, on_delete: :nilify_all)

      add :archived, :boolean, default: false, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:plans, ["COALESCE(owner_user_id, 0)", :slug],
             name: :plans_owner_user_id_slug_index,
             unique: true
           )

    create index(:plans, [:owner_user_id])
    create index(:plans, [:visibility], where: "visibility = 'public'")
  end

  def down do
    drop_if_exists index(:plans, ["COALESCE(owner_user_id, 0)", :slug],
                     name: :plans_owner_user_id_slug_index
                   )

    drop_if_exists index(:plans, [:owner_user_id])
    drop_if_exists index(:plans, [:visibility])
    drop table(:plans)
  end
end
