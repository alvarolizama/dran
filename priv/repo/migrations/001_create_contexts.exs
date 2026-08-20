defmodule Dran.Repo.Migrations.CreateWorkspaces do
  use Ecto.Migration

  def change do
    create table(:workspaces, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :name, :string, size: 100, null: false
      add :slug, :string, size: 100, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:workspaces, [:name])
    create unique_index(:workspaces, [:slug])
  end
end
