defmodule Dran.Repo.Migrations.DropGoalSlugMetaIndex do
  use Ecto.Migration

  def up do
    # Leftover from the goals feature: partial index over
    # knowledge_pages.meta->>'goal_slug'. No reader remains.
    execute(
      "DROP INDEX IF EXISTS knowledge_pages_meta_goal_slug_idx",
      "CREATE INDEX knowledge_pages_meta_goal_slug_idx ON knowledge_pages USING btree (((meta ->> 'goal_slug'::text))) WHERE ((meta ->> 'goal_slug'::text) IS NOT NULL)"
    )
  end

  def down do
    execute(
      "CREATE INDEX knowledge_pages_meta_goal_slug_idx ON knowledge_pages USING btree (((meta ->> 'goal_slug'::text))) WHERE ((meta ->> 'goal_slug'::text) IS NOT NULL)",
      "DROP INDEX IF EXISTS knowledge_pages_meta_goal_slug_idx"
    )
  end
end
