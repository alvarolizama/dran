defmodule Dran.Repo.Migrations.RemoveProjectPageType do
  @moduledoc """
  Removes the `project` page type. Existing project rows become `note`
  pages — `note` is a free type, so their `meta.kind` values (project,
  plan, goal, milestone) survive as legacy display values.

  Symmetric down: restores the rows that were projects by their kind.
  """

  use Ecto.Migration

  def up do
    execute(
      "UPDATE knowledge_pages SET page_type = 'note' WHERE page_type = 'project'",
      "UPDATE knowledge_pages SET page_type = 'project' WHERE page_type = 'note' AND meta->>'kind' IN ('project', 'plan', 'goal', 'milestone')"
    )
  end

  def down do
    execute(
      "UPDATE knowledge_pages SET page_type = 'project' WHERE page_type = 'note' AND meta->>'kind' IN ('project', 'plan', 'goal', 'milestone')",
      "UPDATE knowledge_pages SET page_type = 'note' WHERE page_type = 'project'"
    )
  end
end
