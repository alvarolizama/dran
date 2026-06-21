defmodule Dran.Repo.Migrations.CreateRelations do
  use Ecto.Migration

  def change do
    create table(:relations, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :source_id, references(:pages, type: :binary_id, on_delete: :delete_all), null: false
      add :target_id, references(:pages, type: :binary_id, on_delete: :delete_all), null: false
      add :relation_type, :string, size: 50, default: "related", null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:relations, [:source_id, :target_id, :relation_type])
    create index(:relations, [:source_id], name: :relations_source_idx)
    create index(:relations, [:target_id], name: :relations_target_idx)
  end
end
