defmodule Dran.Repo.Migrations.AddPersonalWorkspaceToUsers do
  use Ecto.Migration

  @moduledoc false

  # Two per-user workspace capabilities:
  #
  #   * `personal_workspace_id` — the user's own workspace, created with the
  #     account and the one they land on by default. It is a pointer (not a
  #     flag on `workspaces`) so renaming the slug never breaks it, and it
  #     NILIFIES on delete: losing the personal workspace must not delete the
  #     user, it just falls back to the legacy landing chain.
  #
  #   * `can_create_workspaces` — permission to create ADDITIONAL workspaces.
  #     Defaults to false: only the instance owner (or an explicitly granted
  #     user) can create workspaces. Personal workspaces are exempt — they are
  #     created by the system, never through this permission.
  def change do
    alter table(:users) do
      add :personal_workspace_id,
          references(:workspaces, type: :binary_id, on_delete: :nilify_all)

      add :can_create_workspaces, :boolean, default: false, null: false
    end

    create index(:users, [:personal_workspace_id])
  end
end
