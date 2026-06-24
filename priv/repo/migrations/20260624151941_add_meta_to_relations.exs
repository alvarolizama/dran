defmodule Dran.Repo.Migrations.AddMetaToRelations do
  use Ecto.Migration

  def change do
    alter table(:relations) do
      add :meta, :map, default: %{}
    end
  end
end
