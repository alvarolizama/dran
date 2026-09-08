defmodule Dran.Repo.Migrations.RenameStepsWorkspaceFk do
  use Ecto.Migration

  def change do
    # Missed by 20260907234045 (the FK list there came from a truncated grep):
    # steps_workspace_id_fkey rides the table rename keeping its old name.
    execute(
      "DO $$ BEGIN ALTER TABLE workflow_steps RENAME CONSTRAINT steps_workspace_id_fkey TO workflow_steps_workspace_id_fkey; " <>
        "EXCEPTION WHEN undefined_object THEN NULL; END $$",
      "DO $$ BEGIN ALTER TABLE workflow_steps RENAME CONSTRAINT workflow_steps_workspace_id_fkey TO steps_workspace_id_fkey; " <>
        "EXCEPTION WHEN undefined_object THEN NULL; END $$"
    )
  end
end
