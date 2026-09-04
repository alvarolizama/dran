defmodule Dran.Repo.Migrations.RepointSessionsToPlans do
  use Ecto.Migration

  @moduledoc """
  Wave B — re-points the execution layer from goals/tasks to plans/steps.

  - `goal_sessions`: ADD `plan_id` (FK → plans, on_delete: :delete_all) and
    `plan_snapshot` (jsonb, default "{}"). `plan_id` becomes NOT NULL after
    the backfill; `goal_id` STAYS as a denormalized convenience column (the
    goal a plan `serves`, resolved at open time and used directly by the
    close-path recompute).
  - `task_runs`: ADD `step_id` (FK → steps, on_delete: :delete_all, nullable —
    legacy F1 rows have no step). `task_id` becomes NULLABLE: since wave B a
    run is keyed by its STEP and the task is spawned by `start_run/1`
    (instance_of), so pending/retried runs legitimately have no task yet.
  - Unique index per `(session_id, step_id, attempt)` (the retry axis moves
    from task to step). The legacy `(session_id, task_id, attempt)` index is
    dropped — spawned tasks are 1:1 per run now, so it is redundant.

  Data backfill (crudo SQL, same transaction feel — each statement is
  idempotent):

  1. For every existing session: plan = the plan whose `serves` relation
     points at the session's goal. `plan_snapshot` = current steps of that
     plan (same shape `open_session/2` freezes: `%{"steps" => [...],
     "edges" => [[from_id, to_id]]}`).
  2. Legacy F1 runs get `step_id` via the wave-A mapping convention
     (`steps.slug = 'step-' || tasks.slug` in the same workspace).
  3. Sessions that cannot resolve a plan are DELETED together with their
     runs (dev data from F1 — there is nothing to run them against).
  """

  def up do
    # ── goal_sessions: plan_id + plan_snapshot ────────────────────────────
    alter table(:goal_sessions) do
      add :plan_id, references(:plans, type: :binary_id, on_delete: :delete_all)

      # Frozen definition the session runs against: steps (id/title/contract)
      # and step→step depends_on edges at open time.
      add :plan_snapshot, :jsonb, default: "{}"
    end

    # Backfill: plan served by the session's goal (if any) + snapshot of its
    # current steps/edges (same JSON shape open_session/1 freezes).
    execute("""
    UPDATE goal_sessions gs
    SET plan_id = p.id,
        plan_snapshot = COALESCE(snap.snapshot, '{}'::jsonb)
    FROM plans p
    JOIN relations serv
      ON serv.source_id = p.id AND serv.source_type = 'plan'
      AND serv.target_type = 'goal' AND serv.relation_type = 'serves'
    JOIN LATERAL (
      SELECT jsonb_build_object(
               'steps',
               COALESCE(
                 jsonb_agg(
                   jsonb_build_object('id', s.id, 'title', s.title, 'contract', s.meta->'contract')
                   ORDER BY s.position, s.inserted_at
                 ),
                 '[]'::jsonb
               ),
               'edges',
               COALESCE(
                 (SELECT jsonb_agg(jsonb_build_array(r.source_id, r.target_id))
                  FROM relations r
                  WHERE r.source_type = 'step' AND r.target_type = 'step'
                    AND r.relation_type = 'depends_on'
                    AND r.source_id IN (SELECT s2.id FROM steps s2 WHERE s2.plan_id = p.id)
                    AND r.target_id IN (SELECT s3.id FROM steps s3 WHERE s3.plan_id = p.id)),
                 '[]'::jsonb
               )
             ) AS snapshot
      FROM steps s
      WHERE s.plan_id = p.id
    ) snap ON true
    WHERE serv.target_id = gs.goal_id
    """)

    # Sessions without a resolvable plan are dev data from F1: deleted with
    # their runs (task_runs.session_id is ON DELETE DELETE_ALL).
    execute("DELETE FROM goal_sessions WHERE plan_id IS NULL")

    execute("ALTER TABLE goal_sessions ALTER COLUMN plan_id SET NOT NULL")

    create index(:goal_sessions, [:plan_id], name: :goal_sessions_plan_id_index)

    # ── task_runs: step_id + nullable task_id ─────────────────────────────
    alter table(:task_runs) do
      add :step_id, references(:steps, type: :binary_id, on_delete: :delete_all)
    end

    # Legacy F1 runs map to their step via the wave-A slug convention
    # ('step-' || task.slug, same workspace). Unmatchable rows are dev data
    # and are removed by the session cleanup above or dropped here.
    execute("""
    UPDATE task_runs r
    SET step_id = s.id
    FROM tasks t, steps s
    WHERE r.task_id = t.id
      AND s.workspace_id = t.workspace_id
      AND s.slug = 'step-' || t.slug
    """)

    # The retry axis moves from task to step: unique per (session, step,
    # attempt). Legacy F1 rows keep their task_id → each gets its own step.
    execute("""
    DELETE FROM task_runs r
    USING task_runs keeper
    WHERE r.step_id IS NOT NULL
      AND keeper.step_id = r.step_id
      AND keeper.session_id = r.session_id
      AND keeper.attempt = r.attempt
      AND keeper.id < r.id
    """)

    execute("DELETE FROM task_runs WHERE step_id IS NULL")

    drop_if_exists index(:task_runs, [:session_id, :task_id, :attempt],
                     name: :task_runs_session_id_task_id_attempt_index
                   )

    create unique_index(:task_runs, [:session_id, :step_id, :attempt],
             name: :task_runs_session_id_step_id_attempt_index
           )

    create index(:task_runs, [:step_id], name: :task_runs_step_id_index)

    # Since wave B the run is keyed by its step; the task is spawned by
    # start_run/1, so pending/retried runs have no task until spawned.
    execute("ALTER TABLE task_runs ALTER COLUMN task_id DROP NOT NULL")
  end

  def down do
    # Legacy shape: task_id back to NOT NULL. Runs without a task have no
    # F1 meaning — removed (dev data of wave B).
    execute("DELETE FROM task_runs WHERE task_id IS NULL")

    drop_if_exists index(:task_runs, [:step_id], name: :task_runs_step_id_index)

    drop_if_exists index(:task_runs, [:session_id, :step_id, :attempt],
                     name: :task_runs_session_id_step_id_attempt_index
                   )

    create unique_index(:task_runs, [:session_id, :task_id, :attempt],
             name: :task_runs_session_id_task_id_attempt_index
           )

    alter table(:task_runs) do
      modify :task_id, :binary_id, null: false
      remove :step_id
    end

    drop_if_exists index(:goal_sessions, [:plan_id], name: :goal_sessions_plan_id_index)

    alter table(:goal_sessions) do
      remove :plan_snapshot
      remove :plan_id
    end
  end
end
