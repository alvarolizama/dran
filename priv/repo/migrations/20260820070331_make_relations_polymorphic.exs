defmodule Dran.Repo.Migrations.MakeRelationsPolymorphic do
  use Ecto.Migration

  def up do
    alter table(:relations) do
      add :source_type, :string, default: "page", null: false
      add :target_type, :string, default: "page", null: false
    end

    # Drop the strict FK constraints — source_id/target_id may now point to
    # goals, projects, or collections table
    drop_if_exists constraint(:relations, :relations_source_id_fkey)
    drop_if_exists constraint(:relations, :relations_target_id_fkey)

    create index(:relations, [:source_id, :source_type])
    create index(:relations, [:target_id, :target_type])
  end

  def down do
    # Restore FK constraints (only valid if no non-page relations exist)
    alter table(:relations) do
      remove :source_type
      remove :target_type
    end

    execute "ALTER TABLE relations ADD CONSTRAINT relations_source_id_fkey
             FOREIGN KEY (source_id) REFERENCES pages(id) ON DELETE CASCADE"
    execute "ALTER TABLE relations ADD CONSTRAINT relations_target_id_fkey
             FOREIGN KEY (target_id) REFERENCES pages(id) ON DELETE CASCADE"
  end
end
