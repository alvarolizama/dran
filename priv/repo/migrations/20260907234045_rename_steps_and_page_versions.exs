defmodule Dran.Repo.Migrations.RenameStepsAndPageVersions do
  use Ecto.Migration

  # Level the remaining namespace prefixes:
  #   steps         -> workflow_steps   (sibling of workflow_runs/workflow_sessions)
  #   page_versions -> knowledge_page_versions (sibling of knowledge_pages)
  #
  # One execute per statement (Postgrex rejects multi-command strings);
  # DO blocks make renames converge from any partial state.
  # FK pointing INTO steps (workflow_runs_step_id_fkey) keeps its name —
  # it is named after the referencing column, not the target table.
  @renames [
    # {table_old, table_new, [{kind, obj_old, obj_new}]}
    {"steps", "workflow_steps",
     [
       {:index, "steps_workflow_id_position_index", "workflow_steps_workflow_id_position_index"},
       {:index, "steps_workflow_id_slug_index", "workflow_steps_workflow_id_slug_index"},
       {:constraint, "steps_pkey", "workflow_steps_pkey"},
       {:constraint, "steps_workflow_id_fkey", "workflow_steps_workflow_id_fkey"}
     ]},
    {"page_versions", "knowledge_page_versions",
     [
       {:index, "page_versions_page_id_index", "knowledge_page_versions_page_id_index"},
       {:index, "page_versions_version_index", "knowledge_page_versions_version_index"},
       {:index, "page_versions_page_version_uidx", "knowledge_page_versions_page_version_uidx"},
       {:constraint, "page_versions_pkey", "knowledge_page_versions_pkey"},
       {:constraint, "page_versions_page_id_fkey", "knowledge_page_versions_page_id_fkey"}
     ]}
  ]

  def change do
    for {old_table, new_table, objs} <- @renames do
      execute(
        "ALTER TABLE #{old_table} RENAME TO #{new_table}",
        "DO $$ BEGIN ALTER TABLE #{new_table} RENAME TO #{old_table}; " <>
          "EXCEPTION WHEN undefined_table THEN NULL; END $$"
      )

      for {kind, old, new} <- objs do
        {up, down} =
          case kind do
            :index ->
              {"DO $$ BEGIN ALTER INDEX IF EXISTS #{old} RENAME TO #{new}; " <>
                 "EXCEPTION WHEN undefined_object THEN NULL; END $$",
               "DO $$ BEGIN ALTER INDEX IF EXISTS #{new} RENAME TO #{old}; " <>
                 "EXCEPTION WHEN undefined_object THEN NULL; END $$"}

            :constraint ->
              {"DO $$ BEGIN ALTER TABLE #{new_table} RENAME CONSTRAINT #{old} TO #{new}; " <>
                 "EXCEPTION WHEN undefined_object THEN NULL; END $$",
               "DO $$ BEGIN ALTER TABLE #{new_table} RENAME CONSTRAINT #{new} TO #{old}; " <>
                 "EXCEPTION WHEN undefined_object THEN NULL; END $$"}
          end

        execute(up, down)
      end
    end
  end
end
