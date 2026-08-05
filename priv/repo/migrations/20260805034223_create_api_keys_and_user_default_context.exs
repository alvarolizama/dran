defmodule Dran.Repo.Migrations.CreateApiKeysAndUserDefaultContext do
  use Ecto.Migration

  def change do
    create table(:api_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :name, :string, null: false
      add :token_hash, :string, null: false
      add :token_prefix, :string, null: false
      add :revoked_at, :utc_datetime

      add :context_id, references(:contexts, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:api_keys, [:token_hash])
    create index(:api_keys, [:context_id])

    alter table(:users) do
      add :default_context_slug, :string
    end
  end
end
