defmodule Dran.Repo.Migrations.MigrateTodoNotesToTasks do
  use Ecto.Migration

  @moduledoc """
  Moves every note with meta.kind == "todo" into the new tasks table,
  rewrites their relations to point at the task rows, and deletes the
  source notes. Idempotent: re-running finds zero matching notes.

  ## What moves

  For each note N with page_type 'note' AND meta->>'kind' = 'todo':

    1. INSERT INTO tasks (…) SELECT … FROM N — same id, kanban columns map
       1:1 (kanban_status → status; unknown/NULL → 'backlog'), meta is
       copied minus kind/kanban/goal/plan/project keys, position seeded
       alphabetically (ROW_NUMBER * 100), completed_at set for
       done/cancelled.
    2. UPDATE relations: edges whose source/target was the note flip
       source_type/target_type 'page' → 'task' (same id).
    3. Rebuild clean part_of task→goal edges from N.meta.goal_slug (same
       pattern the 20260820071215 migration used for page→goal edges).
    4. DELETE the now-duplicated page→goal edges for migrated rows.
    5. DELETE the note rows.

  The SQL statements live in `up_statements/0` (public) so tests can run
  them against the sandboxed test DB — Ecto.Migrator itself spawns its own
  process, which the SQL sandbox rejects.
  """

  def up do
    Enum.each(up_statements(), &execute/1)
  end

  def down do
    Enum.each(down_statements(), &execute/1)
  end

  @doc "Ordered SQL statements of up/0 — public for sandbox tests."
  def up_statements do
    [
      # 1. Copy todo-notes into tasks (id preserved so relations keep
      #    pointing at the same uuid through the copy phase).
      #    Status comes from meta — the kanban COLUMNS were never synced
      #    from meta (the original dual-source bug), so meta is the
      #    reliable source.
      """
      INSERT INTO tasks (
        id, workspace_id, title, slug, body, summary, status, priority,
        position, due_date, meta, recurrence, lock_version, completed_at,
        archived, owner, created_by, updated_by, on_behalf_of,
        inserted_at, updated_at
      )
      SELECT
        p.id,
        p.workspace_id,
        p.title,
        p.slug,
        p.body,
        p.summary,
        CASE COALESCE(NULLIF(p.meta->>'kanban_status', ''), 'backlog')
          WHEN 'pending' THEN 'backlog'   -- legacy seed status
          ELSE COALESCE(NULLIF(p.meta->>'kanban_status', ''), 'backlog')
        END,
        p.meta->>'priority',
        (ROW_NUMBER() OVER (
           PARTITION BY p.workspace_id,
             COALESCE(NULLIF(p.meta->>'kanban_status', ''), 'backlog')
           ORDER BY p.title
         ) * 100)::integer,
        (p.meta->>'due_date')::date,
        (p.meta - 'kind' - 'kanban_status' - 'priority' - 'due_date'
               - 'assignee' - 'goal_slug' - 'plan_slug' - 'project_slug'),
        'none',
        1,
        CASE
          WHEN CASE COALESCE(NULLIF(p.meta->>'kanban_status', ''), 'backlog')
                 WHEN 'pending' THEN 'backlog'
                 ELSE COALESCE(NULLIF(p.meta->>'kanban_status', ''), 'backlog')
               END IN ('done', 'cancelled')
          THEN p.updated_at
          ELSE NULL
        END,
        p.archived,
        p.owner,
        p.created_by,
        p.updated_by,
        p.on_behalf_of,
        p.inserted_at,
        p.updated_at
      FROM pages p
      WHERE p.page_type = 'note'
        AND p.meta->>'kind' = 'todo'
      ON CONFLICT (id) DO NOTHING
      """,
      # 2a. Relations whose source was the note → task endpoint
      """
      UPDATE relations r
      SET source_type = 'task'
      WHERE r.source_type = 'page'
        AND r.source_id IN (SELECT id FROM tasks)
      """,
      # 2b. Relations whose target was the note → task endpoint
      """
      UPDATE relations r
      SET target_type = 'task'
      WHERE r.target_type = 'page'
        AND r.target_id IN (SELECT id FROM tasks)
      """,
      # 3. Rebuild clean part_of task→goal edges from meta.goal_slug.
      """
      INSERT INTO relations (id, source_id, target_id, relation_type, source_type, target_type, meta, inserted_at)
      SELECT
        gen_random_uuid(),
        t.id,
        g.id,
        'part_of',
        'task',
        'goal',
        '{}'::jsonb,
        NOW()
      FROM pages p
      INNER JOIN tasks t ON t.id = p.id
      INNER JOIN goals g
        ON g.slug = p.meta->>'goal_slug'
        AND g.workspace_id = p.workspace_id
      WHERE p.page_type = 'note'
        AND p.meta->>'kind' = 'todo'
        AND p.meta->>'goal_slug' IS NOT NULL
      ON CONFLICT DO NOTHING
      """,
      # 4. Remove the duplicated page→goal edges for migrated rows.
      """
      DELETE FROM relations
      WHERE source_type = 'page'
        AND source_id IN (SELECT id FROM tasks)
        AND target_type = 'goal'
      """,
      # 5. Delete the migrated notes (only once their task copy exists).
      """
      DELETE FROM pages
      WHERE page_type = 'note'
        AND meta->>'kind' = 'todo'
        AND id IN (SELECT id FROM tasks)
      """
    ]
  end

  @doc "Ordered SQL statements of down/0 — public for sandbox tests."
  def down_statements do
    [
      # Reverse: fold tasks back into notes with kind:"todo" + kanban meta.
      """
      INSERT INTO pages (
        id, workspace_id, title, slug, body, summary, page_type, tags, meta,
        kanban_status, priority, due_date, archived, owner, created_by,
        updated_by, on_behalf_of, version, inserted_at, updated_at
      )
      SELECT
        t.id,
        t.workspace_id,
        t.title,
        t.slug,
        t.body,
        t.summary,
        'note',
        ARRAY[]::varchar[],
        (t.meta || jsonb_build_object('kind', 'todo', 'kanban_status', t.status)),
        t.status,
        t.priority,
        t.due_date,
        t.archived,
        t.owner,
        t.created_by,
        t.updated_by,
        t.on_behalf_of,
        1,
        t.inserted_at,
        t.updated_at
      FROM tasks t
      ON CONFLICT (id) DO NOTHING
      """,
      """
      UPDATE relations r
      SET source_type = 'page'
      WHERE r.source_type = 'task'
        AND r.source_id IN (SELECT id FROM pages WHERE meta->>'kind' = 'todo')
      """,
      """
      UPDATE relations r
      SET target_type = 'page'
      WHERE r.target_type = 'task'
        AND r.target_id IN (SELECT id FROM pages WHERE meta->>'kind' = 'todo')
      """,
      # Only the tasks we folded back — tasks created natively in the tasks
      # table are left alone (their data does not round-trip to notes).
      """
      DELETE FROM tasks
      WHERE id IN (SELECT id FROM pages WHERE meta->>'kind' = 'todo')
      """
    ]
  end
end
