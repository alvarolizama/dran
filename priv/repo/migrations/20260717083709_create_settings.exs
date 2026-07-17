defmodule Dran.Repo.Migrations.CreateSettings do
  use Ecto.Migration

  def change do
    create table(:settings, primary_key: false) do
      add :key, :string, primary_key: true
      add :value, :map, null: false, default: %{}
      timestamps(type: :utc_datetime)
    end
  end
end
