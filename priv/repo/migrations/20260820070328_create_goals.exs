defmodule Dran.Repo.Migrations.CreateGoals do
  use Ecto.Migration

  def change do
    create table(:goals, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :title, :string, null: false
      add :slug, :string, null: false
      add :description, :string
      add :body, :string, default: ""
      add :kind, :string
      add :health, :string
      add :status, :string, default: "active"
      add :metric, :string
      add :target_value, :float
      add :current_value, :float
      add :unit, :string
      add :progress, :float
      add :start_date, :date
      add :target_date, :date
      add :team, {:array, :string}, default: []
      add :meta, :map, default: %{}
      add :archived, :boolean, default: false
      add :parent_goal_id, references(:goals, type: :binary_id, on_delete: :nilify_all)

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:goals, [:workspace_id, :slug])
  end
end
