defmodule Dran.Repo.Migrations.DropApiKeys do
  use Ecto.Migration

  @moduledoc """
  W3 (una sola credencial): `api_keys` and `api_key_workspaces` leave the
  schema. The credential is `users.api_token`; no code path reads the key
  tables any more.

  Runs AFTER the code stopped reading them (the old `valid_api_key?/1`
  preloaded the join table, so dropping first would break a live code path).

  `down` recreates a minimal, functional pair of tables so the migration is
  reversible (the historical rows are gone either way — a drop is not a
  rename).
  """

  def up do
    # Join table first: it references api_keys.
    drop table(:api_key_workspaces)
    drop table(:api_keys)
  end

  def down do
    create table(:api_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :name, :string, null: false
      add :token_hash, :string, null: false
      add :token_prefix, :string, null: false
      add :revoked_at, :utc_datetime
      add :created_by_user_id, references(:users, type: :bigint, on_delete: :nilify_all)
      add :actor_id, references(:actors, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:api_keys, [:token_hash])
    create index(:api_keys, [:created_by_user_id])
    create index(:api_keys, [:actor_id], name: :api_keys_actor_id_index)

    create table(:api_key_workspaces, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :api_key_id, references(:api_keys, type: :binary_id, on_delete: :delete_all),
        null: false

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :access_level, :string, default: "read", null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:api_key_workspaces, [:api_key_id, :workspace_id])
    create index(:api_key_workspaces, [:workspace_id])
  end
end
