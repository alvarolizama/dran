defmodule Dran.Repo.Migrations.MakeApiKeysMultiWorkspace do
  use Ecto.Migration

  def up do
    # Create the new association table first
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

    # Migrate existing data: move single workspace to the new table
    execute """
    INSERT INTO api_key_workspaces (id, api_key_id, workspace_id, access_level, inserted_at)
    SELECT gen_random_uuid(), id, workspace_id,
           CASE WHEN write_access THEN 'write' ELSE 'read' END,
           inserted_at
    FROM api_keys
    WHERE workspace_id IS NOT NULL
    """

    # Drop old columns
    alter table(:api_keys) do
      remove :workspace_id
      remove :write_access
      add :created_by_user_id, references(:users, type: :bigint, on_delete: :nilify_all)
    end

    create index(:api_keys, [:created_by_user_id])
  end

  def down do
    alter table(:api_keys) do
      remove :created_by_user_id
      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all)
      add :write_access, :boolean, default: false, null: false
    end

    # Migrate data back (take the first workspace association if any)
    execute """
    UPDATE api_keys
    SET workspace_id = akw.workspace_id,
        write_access = (akw.access_level = 'write')
    FROM api_key_workspaces akw
    WHERE api_keys.id = akw.api_key_id
    AND akw.id = (
      SELECT id FROM api_key_workspaces
      WHERE api_key_id = api_keys.id
      ORDER BY inserted_at
      LIMIT 1
    )
    """

    drop table(:api_key_workspaces)
  end
end
