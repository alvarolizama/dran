defmodule Dran.Repo.Migrations.UniquifyStepSlugToWorkflow do
  @moduledoc """
  Change step.slug uniqueness from `(workspace_id, slug)` → `(workflow_id, slug)`.

  A step is a child of a workflow — two different workflows should be able to
  both have a step called "build". The previous scope was inherited from the
  legacy plans/steps model where the constraint made no sense (a step can't
  exist outside its workflow anyway).

  `put_unique_step_slug/2` already queries within the workflow only — this
  migration aligns the DB constraint with what the code expects.
  """

  use Ecto.Migration

  def change do
    drop_if_exists unique_index(:steps, [:workspace_id, :slug],
                     name: :steps_workspace_id_slug_index
                   )

    create unique_index(:steps, [:workflow_id, :slug], name: :steps_workflow_id_slug_index)
  end
end
