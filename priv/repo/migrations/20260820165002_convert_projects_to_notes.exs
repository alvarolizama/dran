defmodule Dran.Repo.Migrations.ConvertProjectsToNotes do
  use Ecto.Migration

  def up do
    # ── Phase 1: Migrate existing projects → pages (notes with kind:"project") ──
    #
    # Each project row becomes a page row with:
    #   page_type = "note"
    #   meta.kind = "project"
    #   meta.status, meta.health, meta.priority (structured block)
    #   meta.start_date, meta.target_date
    #   body = project.body
    #   summary = project.description
    #   title, slug, workspace_id, archived carried over
    execute """
    INSERT INTO pages (id, workspace_id, title, slug, body, summary, page_type,
      meta, archived, inserted_at, updated_at)
    SELECT
      p.id,
      p.workspace_id,
      p.title,
      p.slug,
      COALESCE(p.body, ''),
      p.description,
      'note',
      jsonb_build_object(
        'kind', 'project',
        'status', COALESCE(p.status, 'active'),
        'health', p.health,
        'priority', p.priority,
        'start_date', CASE WHEN p.start_date IS NULL THEN NULL
                           ELSE to_char(p.start_date, 'YYYY-MM-DD') END,
        'target_date', CASE WHEN p.target_date IS NULL THEN NULL
                             ELSE to_char(p.target_date, 'YYYY-MM-DD') END
      ),
      p.archived,
      p.inserted_at,
      p.updated_at
    FROM projects p
    ON CONFLICT DO NOTHING
    """

    # ── Phase 2: Migrate projects.goal_id → part_of relations (page→goal) ──
    execute """
    INSERT INTO relations (id, source_id, source_type, target_id, target_type,
      relation_type, meta, inserted_at)
    SELECT
      gen_random_uuid(),
      p.id,
      'page',
      g.id,
      'goal',
      'part_of',
      '{}'::jsonb,
      NOW()
    FROM projects p
    INNER JOIN goals g ON g.id = p.goal_id
    WHERE p.goal_id IS NOT NULL
    ON CONFLICT DO NOTHING
    """

    # ── Phase 3: Update existing relations pointing at projects ──
    # Relations where target_type='project' need to point to the new page row.
    # Since the project's id was reused as the page's id, we just change the type.
    execute """
    UPDATE relations
    SET target_type = 'page'
    WHERE target_type = 'project'
    """

    execute """
    UPDATE relations
    SET source_type = 'page'
    WHERE source_type = 'project'
    """

    # ── Phase 4: Drop the projects table ──
    drop_if_exists table(:projects)
  end

  def down do
    # Best-effort reverse: re-create projects table from notes with kind:"project"
    create table(:projects, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :title, :string, null: false
      add :slug, :string, null: false
      add :description, :string
      add :body, :string, default: ""
      add :status, :string, default: "active"
      add :health, :string
      add :priority, :string
      add :start_date, :date
      add :target_date, :date
      add :meta, :map, default: %{}
      add :archived, :boolean, default: false
      add :goal_id, references(:goals, type: :binary_id, on_delete: :nilify_all)

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:projects, [:workspace_id, :slug])

    # Re-insert projects from notes with kind:"project"
    execute """
    INSERT INTO projects (id, title, slug, description, body, status, health,
      priority, start_date, target_date, meta, archived, workspace_id,
      inserted_at, updated_at)
    SELECT
      p.id,
      p.title,
      p.slug,
      p.summary,
      COALESCE(p.body, ''),
      COALESCE(p.meta->>'status', 'active'),
      p.meta->>'health',
      p.meta->>'priority',
      NULLIF(p.meta->>'start_date', '')::date,
      NULLIF(p.meta->>'target_date', '')::date,
      p.meta - 'kind' - 'status' - 'health' - 'priority' - 'start_date' - 'target_date',
      p.archived,
      p.workspace_id,
      p.inserted_at,
      p.updated_at
    FROM pages p
    WHERE p.page_type = 'note' AND p.meta->>'kind' = 'project'
    ON CONFLICT DO NOTHING
    """

    # Delete the migrated notes
    execute "DELETE FROM pages WHERE page_type = 'note' AND meta->>'kind' = 'project'"

    # Restore relation types
    execute "UPDATE relations SET target_type = 'project' WHERE target_type = 'page' AND target_id IN (SELECT id FROM projects)"

    execute "UPDATE relations SET source_type = 'project' WHERE source_type = 'page' AND source_id IN (SELECT id FROM projects)"

    # Remove part_of relations created in Phase 2
    execute """
    DELETE FROM relations
    WHERE relation_type = 'part_of'
      AND source_type = 'page' AND target_type = 'goal'
      AND source_id IN (SELECT id FROM projects)
    """
  end
end
