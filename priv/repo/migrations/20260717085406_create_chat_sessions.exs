defmodule Dran.Repo.Migrations.CreateChatSessions do
  use Ecto.Migration

  def change do
    create table(:chat_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user, :string, null: false, default: "anonymous"
      add :messages, :map, default: %{"items" => []}
      add :page_slug, :string

      timestamps(type: :utc_datetime)
    end

    create index(:chat_sessions, [:workspace_id, :user])
  end
end
