defmodule Dran.Repo.Migrations.AddWikiToWorkspacesAndPinnedToPages do
  use Ecto.Migration

  def change do
    alter table(:workspaces) do
      add :wiki_enabled, :boolean, default: false, null: false
      add :wiki_description, :text
    end

    alter table(:pages) do
      add :pinned, :boolean, default: false, null: false
    end
  end
end
