defmodule Dran.Repo.Migrations.AddRolesToUserWorkspacesAndIsOwnerToUsers do
  use Ecto.Migration

  def up do
    alter table(:user_workspaces) do
      add :role, :string, null: false, default: "viewer"
    end

    create index(:user_workspaces, [:role])

    alter table(:users) do
      add :is_owner, :boolean, null: false, default: false
    end

    # Data migration: map existing is_admin/is_editor to roles
    execute("UPDATE users SET is_owner = true WHERE is_admin = true")

    execute("""
    UPDATE user_workspaces uw
    SET role = 'owner'
    FROM users u
    WHERE uw.user_id = u.id AND u.is_admin = true
    """)

    execute("""
    UPDATE user_workspaces uw
    SET role = 'editor'
    FROM users u
    WHERE uw.user_id = u.id AND u.is_editor = true AND u.is_admin = false
    """)

    # Drop old boolean columns
    alter table(:users) do
      remove :is_admin
      remove :is_editor
    end
  end

  def down do
    alter table(:users) do
      add :is_admin, :boolean, null: false, default: false
      add :is_editor, :boolean, null: false, default: false
    end

    execute("UPDATE users SET is_admin = true WHERE is_owner = true")

    execute("""
    UPDATE users SET is_editor = true
    WHERE id IN (
      SELECT user_id FROM user_workspaces WHERE role IN ('owner', 'editor')
    )
    """)

    alter table(:user_workspaces) do
      remove :role
    end

    alter table(:users) do
      remove :is_owner
    end
  end
end
