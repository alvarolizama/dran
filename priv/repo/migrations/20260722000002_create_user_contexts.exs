defmodule Dran.Repo.Migrations.CreateUserWorkspaces do
  use Ecto.Migration

  def change do
    create table(:user_workspaces) do
      add :user_id, references(:users, on_delete: :delete_all), null: false

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps()
    end

    create unique_index(:user_workspaces, [:user_id, :workspace_id])
  end
end
