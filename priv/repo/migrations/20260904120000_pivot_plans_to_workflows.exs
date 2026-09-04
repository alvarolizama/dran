defmodule Dran.Repo.Migrations.PivotPlansToWorkflows do
  @moduledoc """
  Wave 1 del pivot 2026-09: separar Manual (goals+tasks) de Execution
  (workflows → steps → sessions → runs).

  Rename in-place (preserva ids y datos dev):

  1. `plans` → `workflows` + `status` (draft/active/archived, default
     draft), `kind` (evergreen/one_shot, default evergreen), `goal_id`
     (FK nullable — link opcional de navegación, decisión ?06).
  2. Backfill `workflows.goal_id` desde las relations `serves`
     (plan→goal), luego delete de relations del nodo `plan` y de las
     `instance_of` task→step (artifacts del spawn, wave B).
  3. `steps.plan_id` → `steps.workflow_id`.
  4. `goal_sessions` → `workflow_sessions`; `plan_id` → `workflow_id`;
     `plan_snapshot` → `snapshot`; `goal_id` nullable (el goal ya no es
     requisito de sesión).
  5. `task_runs` → `runs`; drop `task_id` (el run es el único runtime,
     sin spawn); add `progress` jsonb (fase actual + gates parciales,
     overwrite por decisión ?02).
  6. Drop `goals.progress` (goals sin progreso derivado — decisión del
     modelo final).

  Down: reverte la geometría (best-effort — `goals.progress` se recrea
  vacía, `runs.task_id` se recrea NULL; las relations plan/serves/
  instance_of no se restauran: eran estado intermedio del modelo viejo).
  """

  use Ecto.Migration

  def up do
    # 1 ── plans → workflows ──────────────────────────────────────────────
    rename table(:plans), to: table(:workflows)

    execute "ALTER INDEX plans_workspace_id_index RENAME TO workflows_workspace_id_index"

    execute """
    ALTER INDEX plans_workspace_id_slug_index RENAME TO workflows_workspace_id_slug_index
    """

    execute "ALTER TABLE workflows RENAME CONSTRAINT plans_pkey TO workflows_pkey"

    execute """
    ALTER TABLE workflows RENAME CONSTRAINT plans_workspace_id_fkey TO workflows_workspace_id_fkey
    """

    alter table(:workflows) do
      add :status, :string, default: "draft", null: false
      add :kind, :string, default: "evergreen", null: false
      add :goal_id, references(:goals, type: :binary_id, on_delete: :nilify_all)
    end

    create constraint(:workflows, :workflows_status_check,
             check: "status IN ('draft','active','archived')"
           )

    create constraint(:workflows, :workflows_kind_check,
             check: "kind IN ('evergreen','one_shot')"
           )

    # 2 ── backfill goal_id desde serves + limpieza de relations ─────────
    # (1:1 en dev; si un plan servía a N goals el UPDATE deja uno y el
    # resto se pierde con el delete — el link nuevo es 1:0..1 por diseño)
    execute """
    UPDATE workflows w
    SET goal_id = r.target_id
    FROM relations r
    WHERE r.source_id = w.id
      AND r.source_type = 'plan'
      AND r.target_type = 'goal'
      AND r.relation_type = 'serves'
    """

    execute """
    DELETE FROM relations
    WHERE source_type = 'plan' OR target_type = 'plan'
       OR (source_type = 'task' AND target_type = 'step'
           AND relation_type = 'instance_of')
    """

    # 3 ── steps.plan_id → workflow_id ───────────────────────────────────
    rename table(:steps), :plan_id, to: :workflow_id

    execute """
    ALTER INDEX steps_plan_id_position_index RENAME TO steps_workflow_id_position_index
    """

    execute """
    ALTER TABLE steps RENAME CONSTRAINT steps_plan_id_fkey TO steps_workflow_id_fkey
    """

    # 4 ── goal_sessions → workflow_sessions ─────────────────────────────
    rename table(:goal_sessions), to: table(:workflow_sessions)
    rename table(:workflow_sessions), :plan_id, to: :workflow_id
    rename table(:workflow_sessions), :plan_snapshot, to: :snapshot

    execute "ALTER TABLE workflow_sessions ALTER COLUMN goal_id DROP NOT NULL"

    execute """
    ALTER TABLE workflow_sessions RENAME CONSTRAINT goal_sessions_pkey TO workflow_sessions_pkey
    """

    execute """
    ALTER TABLE workflow_sessions RENAME CONSTRAINT goal_sessions_goal_id_fkey TO workflow_sessions_goal_id_fkey
    """

    execute """
    ALTER TABLE workflow_sessions RENAME CONSTRAINT goal_sessions_plan_id_fkey TO workflow_sessions_workflow_id_fkey
    """

    execute """
    ALTER TABLE workflow_sessions RENAME CONSTRAINT goal_sessions_workspace_id_fkey TO workflow_sessions_workspace_id_fkey
    """

    execute """
    ALTER TABLE workflow_sessions RENAME CONSTRAINT goal_sessions_actor_id_fkey TO workflow_sessions_actor_id_fkey
    """

    execute """
    ALTER INDEX goal_sessions_goal_id_index RENAME TO workflow_sessions_goal_id_index
    """

    execute """
    ALTER INDEX goal_sessions_plan_id_index RENAME TO workflow_sessions_workflow_id_index
    """

    execute """
    ALTER INDEX goal_sessions_workspace_id_index RENAME TO workflow_sessions_workspace_id_index
    """

    # 5 ── task_runs → runs (sin task, con progress) ─────────────────────
    rename table(:task_runs), to: table(:runs)

    # task_id se dropea con su FK (task_runs_task_id_fkey) de un golpe
    alter table(:runs) do
      remove :task_id
      add :progress, :jsonb, default: fragment("'{}'::jsonb"), null: false
    end

    execute "ALTER TABLE runs RENAME CONSTRAINT task_runs_pkey TO runs_pkey"

    execute """
    ALTER TABLE runs RENAME CONSTRAINT task_runs_session_id_fkey TO runs_session_id_fkey
    """

    execute """
    ALTER TABLE runs RENAME CONSTRAINT task_runs_step_id_fkey TO runs_step_id_fkey
    """

    execute """
    ALTER TABLE runs RENAME CONSTRAINT task_runs_workspace_id_fkey TO runs_workspace_id_fkey
    """

    execute """
    ALTER TABLE runs RENAME CONSTRAINT task_runs_actor_id_fkey TO runs_actor_id_fkey
    """

    execute """
    ALTER INDEX task_runs_session_id_step_id_attempt_index
      RENAME TO runs_session_id_step_id_attempt_index
    """

    execute "ALTER INDEX task_runs_step_id_index RENAME TO runs_step_id_index"
    execute "ALTER INDEX task_runs_workspace_id_index RENAME TO runs_workspace_id_index"

    # 6 ── goals sin progress ────────────────────────────────────────────
    alter table(:goals) do
      remove :progress
    end
  end

  def down do
    alter table(:goals) do
      add :progress, :float
    end

    rename table(:runs), to: table(:task_runs)

    alter table(:task_runs) do
      remove :progress
      add :task_id, references(:tasks, type: :binary_id, on_delete: :delete_all)
    end

    rename table(:workflow_sessions), to: table(:goal_sessions)
    rename table(:goal_sessions), :workflow_id, to: :plan_id
    rename table(:goal_sessions), :snapshot, to: :plan_snapshot
    execute "ALTER TABLE goal_sessions ALTER COLUMN goal_id SET NOT NULL"

    rename table(:steps), :workflow_id, to: :plan_id
    rename table(:workflows), to: table(:plans)

    alter table(:plans) do
      remove :goal_id
      remove :kind
      remove :status
    end

    # relations plan/serves/instance_of no se restauran (estado intermedio
    # del modelo plans+spawn — ver @moduledoc)
    :ok
  end
end
