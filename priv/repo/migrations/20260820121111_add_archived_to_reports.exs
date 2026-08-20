defmodule Dran.Repo.Migrations.AddArchivedToReports do
  use Ecto.Migration

  def up do
    alter table(:reports) do
      add :archived, :boolean, default: false, null: false
    end
  end

  def down do
    alter table(:reports) do
      remove :archived
    end
  end
end
