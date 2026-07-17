defmodule Dran.Repo.Migrations.AddWeightToRelations do
  use Ecto.Migration

  def change do
    alter table(:relations) do
      add :weight, :float
    end
  end
end
