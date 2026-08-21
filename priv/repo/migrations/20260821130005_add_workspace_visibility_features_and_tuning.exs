defmodule Dran.Repo.Migrations.AddWorkspaceVisibilityFeaturesAndTuning do
  use Ecto.Migration

  def up do
    alter table(:workspaces) do
      add :is_default, :boolean, default: false, null: false
      add :visibility, :string, default: "public", null: false
      add :enabled_features, :map, default: fragment("'{}'::jsonb"), null: false
      add :semantic_threshold_short, :float
      add :semantic_threshold_mid, :float
      add :semantic_threshold_long, :float
      add :entity_linker_enabled, :boolean
      add :agent_max_pages, :integer
    end

    create unique_index(:workspaces, [:is_default], where: "is_default = true")

    # Backfill (single transaction — Postgres migrations are transactional):
    # 1) Copy the global brain-tuning keys from the settings table (stored as
    #    jsonb %{"value" => v}) into every workspace, preserving current
    #    behavior. If no settings row exists for a key, the column stays NULL
    #    and code falls back to Dran.Settings defaults.
    # 2) Mark ONE workspace as the instance default: the workspace matching
    #    the 'personal' slug if it exists, otherwise the oldest workspace by
    #    inserted_at. The partial unique index on is_default=true guarantees
    #    only a single default row.
    execute """
    DO $$
    DECLARE
      v_short FLOAT;
      v_mid FLOAT;
      v_long FLOAT;
      v_entity BOOLEAN;
      v_agent_pages INTEGER;
    BEGIN
      -- Fetch global tuning values (jsonb %{"value" => v}) if they exist
      SELECT (value->>'value')::float INTO v_short FROM settings WHERE key = 'semantic_threshold_short';
      SELECT (value->>'value')::float INTO v_mid FROM settings WHERE key = 'semantic_threshold_mid';
      SELECT (value->>'value')::float INTO v_long FROM settings WHERE key = 'semantic_threshold_long';
      SELECT (value->>'value')::boolean INTO v_entity FROM settings WHERE key = 'entity_linker_enabled';
      SELECT (value->>'value')::integer INTO v_agent_pages FROM settings WHERE key = 'agent_max_pages';

      UPDATE workspaces
      SET
        semantic_threshold_short = COALESCE(v_short, semantic_threshold_short),
        semantic_threshold_mid = COALESCE(v_mid, semantic_threshold_mid),
        semantic_threshold_long = COALESCE(v_long, semantic_threshold_long),
        entity_linker_enabled = COALESCE(v_entity, entity_linker_enabled),
        agent_max_pages = COALESCE(v_agent_pages, agent_max_pages);
    END $$;
    """

    # Mark the default workspace. The env-based slug (Dran.Auth.default_workspace_slug/0)
    # is not readable from a migration, so use the conventional 'personal'
    # slug, falling back to the oldest workspace.
    execute """
    UPDATE workspaces
    SET is_default = true
    WHERE id = COALESCE(
      (SELECT id FROM workspaces WHERE slug = 'personal' LIMIT 1),
      (SELECT id FROM workspaces ORDER BY inserted_at LIMIT 1)
    );
    """
  end

  def down do
    drop unique_index(:workspaces, [:is_default])

    alter table(:workspaces) do
      remove :is_default
      remove :visibility
      remove :enabled_features
      remove :semantic_threshold_short
      remove :semantic_threshold_mid
      remove :semantic_threshold_long
      remove :entity_linker_enabled
      remove :agent_max_pages
    end
  end
end
