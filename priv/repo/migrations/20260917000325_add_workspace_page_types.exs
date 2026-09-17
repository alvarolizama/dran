defmodule Dran.Repo.Migrations.AddWorkspacePageTypes do
  use Ecto.Migration

  @doc """
  W2: per-workspace custom page types.

  `workspace_page_types` is an ORDERED jsonb list of objects:

      {"slug": "recipe", "label": "Receta", "plural": "Recetas",
       "path": "recipes", "icon": "hero-beaker", "color": "amber",
       "meta_fields": [...]}

  `slug` and `path` are explicit and must be unique within the workspace
  (validated in `Dran.Workspace.settings_changeset/2`, not pluralized
  blindly). `path` is the URL segment. Default `[]` follows the
  `enabled_features` jsonb pattern.
  """
  def change do
    alter table(:workspaces) do
      add :workspace_page_types, :jsonb, default: "[]", null: false
    end
  end
end
