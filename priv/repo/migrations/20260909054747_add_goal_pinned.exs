defmodule Dran.Repo.Migrations.AddGoalPinned do
  use Ecto.Migration

  def change do
    alter table(:goals) do
      add :pinned, :boolean, default: false, null: false
    end

    create index(:goals, [:workspace_id, :pinned])
  end
end
