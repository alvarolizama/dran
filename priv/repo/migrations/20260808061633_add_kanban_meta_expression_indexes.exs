defmodule Dran.Repo.Migrations.AddKanbanMetaExpressionIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  # Expression indexes on the hot JSONB meta keys the kanban / todos / planning
  # views filter by (see Dran.Knowledge.list_pages/1). Without these, every
  # `meta->>'kanban_status' = ?`-style filter is a seq scan over pages. They are
  # partial (only rows where the key is present) to keep them small, and built
  # CONCURRENTLY so the table isn't locked on a populated prod database.
  @keys ~w(kanban_status assignee plan_slug goal_slug project_slug)

  def up do
    for key <- @keys do
      create index(
               :pages,
               ["((meta ->> '#{key}'))"],
               name: :"pages_meta_#{key}_idx",
               where: "meta ->> '#{key}' IS NOT NULL",
               concurrently: true
             )
    end
  end

  def down do
    for key <- @keys do
      drop_if_exists index(:pages, name: :"pages_meta_#{key}_idx", concurrently: true)
    end
  end
end
