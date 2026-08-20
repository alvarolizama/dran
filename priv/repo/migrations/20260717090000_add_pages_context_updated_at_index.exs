defmodule Dran.Repo.Migrations.AddPagesContextUpdatedAtIndex do
  @moduledoc """
  Composite index on pages(workspace_id, updated_at DESC).

  Optimizes:
  - Brain.stats/1 recent pages query (WHERE workspace_id = ? ORDER BY updated_at DESC LIMIT 5)
  - Brain.stale_pages/1 (WHERE workspace_id = ? AND updated_at < ?)
  - Brain.list_pages/1 default ordering (ORDER BY updated_at DESC)

  Note: relations(source_id) and relations(target_id) indexes already exist
  (relations_source_idx, relations_target_idx from migration 003).
  """
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create index(:pages, [:workspace_id, :updated_at], name: :pages_context_updated_at_idx)
  end

  def down do
    drop index(:pages, [:workspace_id, :updated_at], name: :pages_context_updated_at_idx)
  end
end
