defmodule Dran.Repo.Migrations.CreateBrainLog do
  use Ecto.Migration

  def change do
    create table(:brain_log, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :context_id, references(:contexts, type: :binary_id, on_delete: :nilify_all), null: true
      add :action, :string, size: 50, null: false
      add :subject, :string, size: 500
      add :details, :map, default: %{}

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:brain_log, [:context_id])
    create index(:brain_log, [:action])
  end
end
