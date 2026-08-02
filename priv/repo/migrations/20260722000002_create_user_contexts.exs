defmodule Dran.Repo.Migrations.CreateUserContexts do
  use Ecto.Migration

  def change do
    create table(:user_contexts) do
      add :user_id, references(:users, on_delete: :delete_all), null: false

      add :context_id, references(:contexts, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps()
    end

    create unique_index(:user_contexts, [:user_id, :context_id])
  end
end
