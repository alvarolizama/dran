defmodule Dran.Repo.Migrations.CreateGoalsAndTasks do
  @moduledoc """
  El contenedor de trabajo de Dran: `goals` con sus `tasks`.

  Portado del código borrado (`1f6399e^`) al modelo ACTUAL — instancia única
  (sin `workspace_id`), visibilidad por ítem (`visibility` + `owner_user_id` en
  el goal) y credencial de cuenta (sin `assignee_actor_id` / `creator_actor_id`).
  No se restaura el código viejo: se reescribe contra el modelo vigente.

  ## El invariante es del MOTOR

  `tasks.goal_id` es `NOT NULL` con FK `on_delete: :delete_all`: una task no
  puede existir sin goal y borrar el goal borra sus tasks, no las deja
  huérfanas. No es una validación de app (contract Constraint 11 / F37).

  ## La visibilidad no vive en la task

  `tasks` NO declara `visibility` ni `owner_user_id`: la lectura se deriva del
  goal por join + `Dran.ContentVisibility.filter/3`. Una columna que nada
  consulta se envía como garantía y no filtra (Constraint 12 / F2).

  ## Checklist

  `tasks.checklist` es jsonb `[%{"text" => _, "done" => _}]` — texto que se
  tacha. No hay tabla `plans` ni `checklist_items`: el plan es una página de
  tipo declarado por instancia con un campo `:checklist` (Constraint 16).
  """

  use Ecto.Migration

  def change do
    create table(:goals, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :title, :string, null: false
      add :slug, :string, null: false
      add :summary, :string
      add :body, :text, default: ""

      # El tiempo es un campo del goal (horizonte + fechas), no una fila por
      # período: "hoy"/"esta semana" son filtros sobre esto (A19).
      add :horizon, :string
      add :starts_on, :date
      add :due_on, :date

      add :status, :string, default: "active", null: false

      # Jerarquía opcional; un goal raíz no tiene padre.
      add :parent_goal_id, references(:goals, type: :binary_id, on_delete: :nilify_all)

      # Override manual del progreso (cubre el goal sin tasks); NULL = derivado
      # de las tasks (done/total).
      add :progress_manual, :integer

      add :pinned, :boolean, default: false, null: false

      # Visibilidad por ítem (el dueño y su política de lectura).
      add :visibility, :string, default: "private", null: false
      add :owner_user_id, references(:users, on_delete: :nilify_all)

      add :archived, :boolean, default: false, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:goals, [:visibility], where: "visibility = 'public'")
    create index(:goals, [:owner_user_id])
    create index(:goals, [:parent_goal_id])

    # El slug es único por dueño (W4a baja la unicidad global a (dueño, tipo));
    # los NULL son distintos en un índice único, así que el contenido de
    # sistema (sin dueño) vive en su propio balde.
    create unique_index(:goals, [:owner_user_id, :slug], name: :goals_owner_user_id_slug_index)

    create table(:tasks, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      # ── El invariante del motor ──
      add :goal_id, references(:goals, type: :binary_id, on_delete: :delete_all), null: false

      add :title, :string, null: false
      add :slug, :string, null: false
      add :body, :text, default: ""

      add :status, :string, default: "backlog", null: false
      add :priority, :string

      # Orden dentro de la columna, con gap de 100.
      add :position, :integer, default: 0, null: false

      add :due_date, :date
      add :assignee_id, references(:users, on_delete: :nilify_all)

      # Texto que se tacha — no comparte ítem con el kanban (estado/asignado/
      # fecha son columnas de la task).
      add :checklist, :map, default: fragment("'[]'::jsonb")

      add :recurrence, :string, default: "none", null: false

      # Bloqueo optimista para mover sin perder updates concurrentes.
      add :lock_version, :integer, default: 1, null: false
      add :completed_at, :utc_datetime

      add :archived, :boolean, default: false, null: false

      timestamps(type: :utc_datetime)
    end

    # Board por goal: WHERE goal_id AND status ORDER BY position.
    create index(:tasks, [:goal_id, :status, :position])
    create index(:tasks, [:goal_id])
    create index(:tasks, [:goal_id, :assignee_id])

    create unique_index(:tasks, [:goal_id, :slug], name: :tasks_goal_id_slug_index)
  end
end
