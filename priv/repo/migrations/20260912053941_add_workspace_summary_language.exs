defmodule Dran.Repo.Migrations.AddWorkspaceSummaryLanguage do
  use Ecto.Migration

  def up do
    alter table(:workspaces) do
      add :summary_language, :string
    end
  end

  def down do
    alter table(:workspaces) do
      remove :summary_language
    end
  end
end
