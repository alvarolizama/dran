defmodule Dran.Repo.Migrations.AddArchivedToPages do
  use Ecto.Migration

  def change do
    alter table(:pages) do
      add :archived, :boolean, null: false, default: false
    end

    create index(:pages, [:context_id, :archived])
  end
end
