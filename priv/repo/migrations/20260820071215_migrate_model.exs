defmodule Dran.Repo.Migrations.MigrateModel do
  use Ecto.Migration

  def up do
    # ── Phase 0: widen columns that receive unbounded page data ──────────────
    # The receiver tables were created with :string (varchar 255) for columns
    # that get pages.title/slug (varchar 500) and pages.summary/body (text).
    # A legacy page with a long title/summary/body aborted this migration with
    # 22001 string_data_right_truncation. varchar→text is a metadata-only
    # change (no table rewrite); on fresh databases this is a redundant no-op.
    # title/slug stay varchar(255) and are truncated with left() instead, so
    # the resulting schema matches a fresh bootstrap exactly.
    execute "ALTER TABLE goals ALTER COLUMN description TYPE text"
    execute "ALTER TABLE goals ALTER COLUMN body TYPE text"
    execute "ALTER TABLE projects ALTER COLUMN description TYPE text"
    execute "ALTER TABLE projects ALTER COLUMN body TYPE text"
    execute "ALTER TABLE collections ALTER COLUMN description TYPE text"
    execute "ALTER TABLE reports ALTER COLUMN body TYPE text"

    # ── Phase 1: goals → goals table ──────────────────────────────────────────
    execute """
    INSERT INTO goals (id, title, slug, description, body, kind, health, status,
      metric, target_value, current_value, unit, progress, start_date, target_date,
      team, meta, archived, workspace_id, inserted_at, updated_at)
    SELECT
      p.id,
      left(p.title, 255),
      left(p.slug, 255),
      left(p.summary, 255),
      COALESCE(p.body, ''),
      p.meta->>'kind',
      p.meta->>'health',
      'active',
      p.meta->>'metric',
      (p.meta->>'target_value')::float,
      (p.meta->>'current_value')::float,
      p.meta->>'unit',
      (p.meta->>'progress')::float,
      (p.meta->>'start_date')::date,
      (p.meta->>'target_date')::date,
      COALESCE(p.meta->>'team', '{}')::text[],
      p.meta,
      p.archived,
      p.workspace_id,
      p.inserted_at,
      p.updated_at
    FROM pages p
    WHERE p.page_type = 'goal'
    ON CONFLICT DO NOTHING
    """

    # Column widths: the goals table predates the fix and uses varchar(255)
    # for title/slug/description while pages keeps title/slug at varchar(500)
    # and summary as unbounded text — truncate defensively so a legacy page
    # with a long title/summary can't abort the migration (22001).

    # ── Phase 2: projects → projects table ────────────────────────────────────
    execute """
    INSERT INTO projects (id, title, slug, description, body, status, health, priority,
      start_date, target_date, meta, archived, workspace_id, inserted_at, updated_at)
    SELECT
      p.id,
      left(p.title, 255),
      left(p.slug, 255),
      left(p.summary, 255),
      COALESCE(p.body, ''),
      left(COALESCE(p.meta->>'status', 'active'), 255),
      p.meta->>'health',
      p.meta->>'priority',
      (p.meta->>'start_date')::date,
      (p.meta->>'target_date')::date,
      p.meta,
      p.archived,
      p.workspace_id,
      p.inserted_at,
      p.updated_at
    FROM pages p
    WHERE p.page_type = 'project'
    ON CONFLICT DO NOTHING
    """

    # ── Phase 3: smart collections → collections table ────────────────────────
    execute """
    INSERT INTO collections (id, name, slug, description, filters, workspace_id, inserted_at, updated_at)
    SELECT
      p.id,
      left(p.title, 255),
      left(p.slug, 255),
      left(p.summary, 255),
      p.meta->'query',
      p.workspace_id,
      p.inserted_at,
      p.updated_at
    FROM pages p
    WHERE p.page_type = 'query'
      AND p.meta->>'query' IS NOT NULL
    ON CONFLICT DO NOTHING
    """

    # ── Phase 4: reports → reports table ──────────────────────────────────────
    execute """
    INSERT INTO reports (id, title, slug, body, report_type, meta, workspace_id, inserted_at, updated_at)
    SELECT
      p.id,
      left(p.title, 255),
      left(p.slug, 255),
      COALESCE(p.body, ''),
      left(COALESCE(p.meta->>'report_type', 'log'), 255),
      p.meta,
      p.workspace_id,
      p.inserted_at,
      p.updated_at
    FROM pages p
    WHERE p.page_type = 'report'
    ON CONFLICT DO NOTHING
    """

    # ── Phase 5: todos → notes (kind:todo) + populate kanban columns ──────────
    execute """
    UPDATE pages
    SET
      page_type = 'note',
      meta = jsonb_set(
        meta - 'project_slug' - 'goal_slug' - 'plan_slug',
        '{kind}', '"todo"'
      ),
      kanban_status = meta->>'kanban_status',
      priority = meta->>'priority',
      due_date = (meta->>'due_date')::date,
      assignee = meta->>'assignee'
    WHERE page_type = 'todo'
    """

    # ── Phase 6: plans → notes (kind:plan) ───────────────────────────────────
    execute """
    UPDATE pages
    SET
      page_type = 'note',
      meta = jsonb_set(
        meta - 'goal_slug' - 'project_slug',
        '{kind}', '"plan"'
      )
    WHERE page_type = 'plan'
    """

    # ── Phase 7: rebuild polymorphic relations from meta slugs ────────────────
    # part_of relations for pages still referencing goals via meta.goal_slug
    execute """
    INSERT INTO relations (id, source_id, target_id, relation_type, source_type, target_type, meta, inserted_at)
    SELECT
      gen_random_uuid(),
      p.id,
      g.id,
      'part_of',
      'page',
      'goal',
      '{}'::jsonb,
      NOW()
    FROM pages p
    INNER JOIN goals g
      ON g.slug = p.meta->>'goal_slug'
      AND g.workspace_id = p.workspace_id
    WHERE p.meta->>'goal_slug' IS NOT NULL
      AND p.page_type = 'note'
    ON CONFLICT DO NOTHING
    """

    # part_of relations for pages still referencing projects via meta.project_slug
    execute """
    INSERT INTO relations (id, source_id, target_id, relation_type, source_type, target_type, meta, inserted_at)
    SELECT
      gen_random_uuid(),
      p.id,
      pr.id,
      'part_of',
      'page',
      'project',
      '{}'::jsonb,
      NOW()
    FROM pages p
    INNER JOIN projects pr
      ON pr.slug = p.meta->>'project_slug'
      AND pr.workspace_id = p.workspace_id
    WHERE p.meta->>'project_slug' IS NOT NULL
      AND p.page_type = 'note'
    ON CONFLICT DO NOTHING
    """

    # ── Phase 8: delete old goal/project page rows ────────────────────────────
    # Relations from goal/project pages point into the new tables; deleting the
    # page rows won't orphan those because the FK was already dropped by Wave 1.
    execute "DELETE FROM pages WHERE page_type = 'goal'"
    execute "DELETE FROM pages WHERE page_type = 'project'"

    # ── Phase 9: cleanup meta — remove slug keys that have been materialised ──
    execute """
    UPDATE pages
    SET meta = meta - 'goal_slug' - 'project_slug' - 'plan_slug'
    WHERE meta ? 'goal_slug' OR meta ? 'project_slug' OR meta ? 'plan_slug'
    """

    # ── Phase 10: delete migrated query pages (smart collections) ─────────────
    # These pages now live in the collections table; the "query" page_type still
    # exists for GraphRAG answer pages (no meta.query), so only delete pages
    # that were migrated into the collections table in Phase 3.
    execute """
    DELETE FROM pages
    WHERE page_type = 'query'
      AND meta->>'query' IS NOT NULL
    """
  end

  def down do
    # Best-effort reverse: re-insert pages from the new tables.

    # Re-insert goals back into pages
    execute """
    INSERT INTO pages (id, workspace_id, title, slug, body, summary, page_type, meta,
                       archived, inserted_at, updated_at)
    SELECT id, workspace_id, title, slug, COALESCE(body, ''), description, 'goal',
           meta, archived, inserted_at, updated_at
    FROM goals
    ON CONFLICT DO NOTHING
    """

    # Re-insert projects back into pages
    execute """
    INSERT INTO pages (id, workspace_id, title, slug, body, summary, page_type, meta,
                       archived, inserted_at, updated_at)
    SELECT id, workspace_id, title, slug, COALESCE(body, ''), description, 'project',
           meta, archived, inserted_at, updated_at
    FROM projects
    ON CONFLICT DO NOTHING
    """

    # Re-insert collections back as query pages (best-effort: put filters into meta.query)
    execute """
    INSERT INTO pages (id, workspace_id, title, slug, body, summary, page_type, meta,
                       inserted_at, updated_at)
    SELECT id, workspace_id, name, slug, '', description, 'query',
           jsonb_build_object('query', filters), inserted_at, updated_at
    FROM collections
    ON CONFLICT DO NOTHING
    """

    # Re-insert reports back into pages
    execute """
    INSERT INTO pages (id, workspace_id, title, slug, body, page_type, meta,
                       inserted_at, updated_at)
    SELECT id, workspace_id, title, slug, COALESCE(body, ''), 'report',
           meta, inserted_at, updated_at
    FROM reports
    ON CONFLICT DO NOTHING
    """

    # Convert notes kind:todo → page_type: todo
    execute """
    UPDATE pages
    SET page_type = 'todo',
        meta = meta - 'kind',
        kanban_status = NULL,
        priority = NULL,
        due_date = NULL,
        assignee = NULL
    WHERE page_type = 'note' AND meta->>'kind' = 'todo'
    """

    # Convert notes kind:plan → page_type: plan
    execute """
    UPDATE pages
    SET page_type = 'plan',
        meta = meta - 'kind'
    WHERE page_type = 'note' AND meta->>'kind' = 'plan'
    """

    # Remove the part_of relations created in Phase 7
    execute """
    DELETE FROM relations
    WHERE relation_type = 'part_of'
      AND (
        (source_type = 'page' AND target_type = 'goal')
        OR (source_type = 'page' AND target_type = 'project')
      )
    """
  end
end
