defmodule Dran.Repo.Migrations.BackfillPlansFromGoals do
  use Ecto.Migration

  @moduledoc """
  Data migration (wave A): converts today's IMPLICIT goal-plans into explicit
  `plans` + `steps` + new relation types, without touching the original data
  (dual until F3 — the goal, its part_of tasks and the task→task depends_on
  edges stay intact).

  For every goal that has at least one `part_of` task:

  1. `plans` row: title/summary/body copied from the goal, slug
     `plan-<goal.slug>` (unique per workspace, idempotent via
     `ON CONFLICT (workspace_id, slug) DO NOTHING`).
  2. `steps` rows: one per part_of task (title, body, `meta` limited to the
     `contract` key, position = row_number*100) — `steps.plan_id` is the
     direct structural FK.
  3. `relations` row plan `serves` goal.
  4. `relations` rows step→step `depends_on`: every task→task depends_on
     edge whose BOTH endpoints became steps is copied (task_id → step_id
     mapping inlined as subqueries).

  Never deletes anything. Idempotent: re-executing is a no-op (unique slugs
  + unique relation triple + ON CONFLICT guards).

  The up statements are exposed as a FLAT list in `up_statements/0` so the
  test harness can replay them inside the sandbox transaction (same
  technique as tasks_migration_test.exs); `up/0` feeds from the same list.
  """

  def up_statements do
    [
      # 1. One plan per goal with ≥1 part_of task.
      """
      INSERT INTO plans (id, workspace_id, title, slug, summary, body, meta, inserted_at, updated_at)
      SELECT gen_random_uuid(),
             g.workspace_id,
             g.title,
             'plan-' || g.slug,
             g.summary,
             g.body,
             '{}'::jsonb,
             now(),
             now()
      FROM goals g
      WHERE EXISTS (
        SELECT 1
        FROM relations r
        JOIN tasks t ON t.id = r.source_id
        WHERE r.target_id = g.id
          AND r.target_type = 'goal'
          AND r.source_type = 'task'
          AND r.relation_type = 'part_of'
          AND t.archived = false
      )
      ON CONFLICT (workspace_id, slug) DO NOTHING
      """,
      # 2. One step per part_of task (idempotent per (workspace_id, slug)).
      """
      INSERT INTO steps (id, workspace_id, plan_id, title, slug, body, position, meta, inserted_at, updated_at)
      SELECT gen_random_uuid(),
             t.workspace_id,
             p.id,
             t.title,
             'step-' || t.slug,
             t.body,
             (row_number() OVER (PARTITION BY r.target_id ORDER BY t.position, t.id)) * 100,
             (CASE WHEN t.meta->'contract' IS NULL
                   THEN '{}'::jsonb
                   ELSE jsonb_build_object('contract', t.meta->'contract')
              END),
             now(),
             now()
      FROM relations r
      JOIN tasks t ON t.id = r.source_id
      JOIN plans p ON p.workspace_id = t.workspace_id AND p.slug = 'plan-' || (
        SELECT g.slug FROM goals g WHERE g.id = r.target_id
      )
      WHERE r.target_type = 'goal'
        AND r.source_type = 'task'
        AND r.relation_type = 'part_of'
        AND t.archived = false
        AND NOT EXISTS (
          SELECT 1 FROM steps s WHERE s.workspace_id = t.workspace_id AND s.slug = 'step-' || t.slug
        )
      """,
      # 3. plan serves goal (idempotent via the unique relation triple).
      """
      INSERT INTO relations (id, source_id, source_type, target_id, target_type, relation_type, weight, meta, inserted_at)
      SELECT gen_random_uuid(), p.id, 'plan', g.id, 'goal', 'serves', 1.0, '{}'::jsonb, now()
      FROM goals g
      JOIN plans p ON p.workspace_id = g.workspace_id AND p.slug = 'plan-' || g.slug
      ON CONFLICT (source_id, target_id, relation_type) DO NOTHING
      """,
      # 4. Copy task→task depends_on edges as step→step where BOTH endpoints
      #    became steps (task_id → step_id mapping inlined — no temp state;
      #    idempotent via the unique relation triple).
      """
      INSERT INTO relations (id, source_id, source_type, target_id, target_type, relation_type, weight, meta, inserted_at)
      SELECT gen_random_uuid(),
             sm_source.step_id,
             'step',
             sm_target.step_id,
             'step',
             'depends_on',
             r.weight,
             r.meta,
             now()
      FROM relations r
      JOIN (
        SELECT t.id AS task_id, s.id AS step_id
        FROM steps s
        JOIN tasks t ON t.workspace_id = s.workspace_id AND s.slug = 'step-' || t.slug
      ) sm_source ON sm_source.task_id = r.source_id
      JOIN (
        SELECT t.id AS task_id, s.id AS step_id
        FROM steps s
        JOIN tasks t ON t.workspace_id = s.workspace_id AND s.slug = 'step-' || t.slug
      ) sm_target ON sm_target.task_id = r.target_id
      WHERE r.relation_type = 'depends_on'
        AND r.source_type = 'task'
        AND r.target_type = 'task'
      ON CONFLICT (source_id, target_id, relation_type) DO NOTHING
      """
    ]
  end

  def up do
    Enum.each(up_statements(), &execute/1)
  end

  def down do
    # Data migration: nothing to downgrade by design. The source tasks, goals
    # and their edges are untouched (dual until F3); the schema-level down is
    # handled by the previous migration (deletes the new-type relation rows
    # and drops the tables).
    :ok
  end
end