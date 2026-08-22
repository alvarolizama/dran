defmodule Dran.Repo.Migrations.RenameCommunitiesToClusters do
  use Ecto.Migration

  def up do
    # Rename the table
    rename table(:community_summaries), to: table(:cluster_summaries)

    # Rename the column (community_id → cluster_id)
    rename table(:cluster_summaries), :community_id, to: :cluster_id

    # Update the unique index
    drop_if_exists index(:cluster_summaries, [:workspace_id, :community_id])

    create unique_index(:cluster_summaries, [:workspace_id, :cluster_id])

    # Migrate meta["community_id"] → meta["cluster_id"] in pages
    execute """
    UPDATE pages
    SET meta = (meta - 'community_id') || jsonb_build_object('cluster_id', meta->>'community_id')
    WHERE meta ? 'community_id'
    """

    # Migrate enabled_features["communities"] → enabled_features["clusters"] in workspaces
    execute """
    UPDATE workspaces
    SET enabled_features = (enabled_features - 'communities') || jsonb_build_object('clusters', enabled_features->>'communities')
    WHERE enabled_features ? 'communities'
    """
  end

  def down do
    rename table(:cluster_summaries), to: table(:community_summaries)

    rename table(:community_summaries), :cluster_id, to: :community_id

    drop_if_exists index(:community_summaries, [:workspace_id, :cluster_id])

    create unique_index(:community_summaries, [:workspace_id, :community_id])

    execute """
    UPDATE pages
    SET meta = (meta - 'cluster_id') || jsonb_build_object('community_id', meta->>'cluster_id')
    WHERE meta ? 'cluster_id'
    """

    execute """
    UPDATE workspaces
    SET enabled_features = (enabled_features - 'clusters') || jsonb_build_object('communities', enabled_features->>'clusters')
    WHERE enabled_features ? 'clusters'
    """
  end
end
