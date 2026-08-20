defmodule Dran.Repo.Migrations.DropWikiFieldsFromWorkspaces do
  use Ecto.Migration

  def up do
    alter table(:workspaces) do
      remove :wiki_enabled
      remove :wiki_description
    end
  end

  def down do
    alter table(:workspaces) do
      add :wiki_enabled, :boolean, default: false, null: false
      add :wiki_description, :string
    end
  end
end
