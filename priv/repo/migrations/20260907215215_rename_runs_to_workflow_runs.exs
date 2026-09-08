defmodule Dran.Repo.Migrations.RenameRunsToWorkflowRuns do
  use Ecto.Migration

  def change do
    # One execute per statement (Postgrex prepared statements reject
    # multi-command strings). DO blocks make renames conditional so a
    # partial application converges instead of crashing.
    #
    # Names (verified against structure.sql pre-rename):
    #   indexes    : runs_session_id_step_id_attempt_index (UNIQUE),
    #                runs_step_id_index, runs_workspace_id_index
    #   constraints: runs_pkey, runs_actor_id_fkey, runs_session_id_fkey,
    #                runs_step_id_fkey, runs_workspace_id_fkey

    renames = [
      # {kind, old, new}
      {:table, "runs", "workflow_runs"},
      {:index, "runs_session_id_step_id_attempt_index",
       "workflow_runs_session_id_step_id_attempt_index"},
      {:index, "runs_step_id_index", "workflow_runs_step_id_index"},
      {:index, "runs_workspace_id_index", "workflow_runs_workspace_id_index"},
      {:constraint, "runs_pkey", "workflow_runs_pkey"},
      {:constraint, "runs_actor_id_fkey", "workflow_runs_actor_id_fkey"},
      {:constraint, "runs_session_id_fkey", "workflow_runs_session_id_fkey"},
      {:constraint, "runs_step_id_fkey", "workflow_runs_step_id_fkey"},
      {:constraint, "runs_workspace_id_fkey", "workflow_runs_workspace_id_fkey"}
    ]

    for {kind, old, new} <- renames do
      up =
        case kind do
          :table ->
            "ALTER TABLE runs RENAME TO workflow_runs"

          :index ->
            "DO $$ BEGIN ALTER INDEX IF EXISTS #{old} RENAME TO #{new}; " <>
              "EXCEPTION WHEN undefined_object THEN NULL; END $$"

          :constraint ->
            "DO $$ BEGIN ALTER TABLE workflow_runs RENAME CONSTRAINT #{old} TO #{new}; " <>
              "EXCEPTION WHEN undefined_object THEN NULL; END $$"
        end

      down =
        case kind do
          :table ->
            "DO $$ BEGIN ALTER TABLE workflow_runs RENAME TO runs; " <>
              "EXCEPTION WHEN undefined_table THEN NULL; END $$"

          :index ->
            "DO $$ BEGIN ALTER INDEX IF EXISTS #{new} RENAME TO #{old}; " <>
              "EXCEPTION WHEN undefined_object THEN NULL; END $$"

          :constraint ->
            "DO $$ BEGIN ALTER TABLE workflow_runs RENAME CONSTRAINT #{new} TO #{old}; " <>
              "EXCEPTION WHEN undefined_object THEN NULL; END $$"
        end

      execute(up, down)
    end
  end
end
