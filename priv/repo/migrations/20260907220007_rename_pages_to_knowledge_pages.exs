defmodule Dran.Repo.Migrations.RenamePagesToKnowledgePages do
  use Ecto.Migration

  @table_renames [{"pages", "knowledge_pages"}]

  # Indexes and constraints verified against structure.sql pre-rename.
  @obj_renames [
    {:index, "pages_context_updated_at_idx"},
    {:index, "pages_ctx_type_archived_idx"},
    {:index, "pages_ctx_type_idx"},
    {:index, "pages_embedding_idx"},
    {:index, "pages_meta_assignee_idx"},
    {:index, "pages_meta_goal_slug_idx"},
    {:index, "pages_meta_idx"},
    {:index, "pages_meta_kanban_status_idx"},
    {:index, "pages_meta_plan_slug_idx"},
    {:index, "pages_meta_project_slug_idx"},
    {:index, "pages_search_idx"},
    {:index, "pages_tags_idx"},
    {:index, "pages_trgm_idx"},
    {:index, "pages_type_idx"},
    {:index, "pages_workspace_id_archived_index"},
    {:index, "pages_workspace_id_slug_idx"},
    {:index, "pages_workspace_id_slug_index"},
    {:constraint, "pages_pkey"},
    {:constraint, "pages_workspace_id_fkey"}
  ]

  def change do
    # One execute per statement (Postgrex rejects multi-command strings).
    # DO blocks make renames conditional so partial application converges.
    for {old, new} <- @table_renames do
      execute(
        "ALTER TABLE #{old} RENAME TO #{new}",
        "DO $$ BEGIN ALTER TABLE #{new} RENAME TO #{old}; " <>
          "EXCEPTION WHEN undefined_table THEN NULL; END $$"
      )
    end

    for {kind, old} <- @obj_renames do
      new = String.replace(old, ~r{\Apages_}, "knowledge_pages_")

      {up, down} =
        case kind do
          :index ->
            {"DO $$ BEGIN ALTER INDEX IF EXISTS #{old} RENAME TO #{new}; " <>
               "EXCEPTION WHEN undefined_object THEN NULL; END $$",
             "DO $$ BEGIN ALTER INDEX IF EXISTS #{new} RENAME TO #{old}; " <>
               "EXCEPTION WHEN undefined_object THEN NULL; END $$"}

          :constraint ->
            {"DO $$ BEGIN ALTER TABLE knowledge_pages RENAME CONSTRAINT #{old} TO #{new}; " <>
               "EXCEPTION WHEN undefined_object THEN NULL; END $$",
             "DO $$ BEGIN ALTER TABLE knowledge_pages RENAME CONSTRAINT #{new} TO #{old}; " <>
               "EXCEPTION WHEN undefined_object THEN NULL; END $$"}
        end

      execute(up, down)
    end
  end
end
