defmodule Dran.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :email, :string, null: false
      add :name, :string
      add :google_id, :string
      add :avatar_url, :string
      add :is_admin, :boolean, default: false, null: false
      add :api_token, :string, null: false

      timestamps()
    end

    create unique_index(:users, [:email])
    create unique_index(:users, [:google_id])
    create unique_index(:users, [:api_token])
  end
end
