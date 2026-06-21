defmodule Dran.Repo.Migrations.AddOwnerFieldsAndMetaIndex do
  use Ecto.Migration

  def up do
    alter table(:pages) do
      add :owner, :string, null: false, default: "system"
      add :created_by, :string, null: false, default: "system"
      add :updated_by, :string
      add :on_behalf_of, :string
    end

    # GIN index on meta JSONB for fast key/path lookups
    execute "CREATE INDEX pages_meta_idx ON pages USING GIN (meta)"
  end

  def down do
    execute "DROP INDEX IF EXISTS pages_meta_idx"

    alter table(:pages) do
      remove :owner
      remove :created_by
      remove :updated_by
      remove :on_behalf_of
    end
  end
end
