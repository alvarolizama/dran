defmodule Dran.Repo.Migrations.CreateCommunitySummaries do
  use Ecto.Migration

  def change do
    create table(:community_summaries, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :context_id, references(:contexts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :community_id, :integer, null: false
      add :summary, :text, null: false
      add :page_count, :integer, default: 0
      add :top_pages, :map, default: fragment("'[]'::jsonb")
      add :generated_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:community_summaries, [:context_id, :community_id])
    create index(:community_summaries, [:context_id])
  end
end
