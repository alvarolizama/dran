defmodule Dran.Repo.Migrations.CreatePageVersions do
  use Ecto.Migration

  def change do
    create table(:page_versions, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :page_id, references(:pages, type: :binary_id, on_delete: :delete_all), null: false
      add :body, :text, null: false
      add :body_hash, :string, size: 64
      add :version, :integer, null: false
      add :changed_by, :string, size: 200

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:page_versions, [:page_id])
    create index(:page_versions, [:version])
  end
end
