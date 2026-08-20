defmodule Dran.Repo.Migrations.CreateProjects do
  use Ecto.Migration

  def change do
    create table(:projects, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :title, :string, null: false
      add :slug, :string, null: false
      add :description, :string
      add :body, :string, default: ""
      add :status, :string, default: "active"
      add :health, :string
      add :priority, :string
      add :start_date, :date
      add :target_date, :date
      add :meta, :map, default: %{}
      add :archived, :boolean, default: false
      add :goal_id, references(:goals, type: :binary_id, on_delete: :nilify_all)

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:projects, [:workspace_id, :slug])
  end
end
