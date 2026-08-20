defmodule Dran.Repo.Migrations.CreateReports do
  use Ecto.Migration

  def change do
    create table(:reports, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :title, :string, null: false
      add :slug, :string, null: false
      add :body, :string, default: ""
      add :report_type, :string
      add :meta, :map, default: %{}

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:reports, [:workspace_id, :slug])
  end
end
