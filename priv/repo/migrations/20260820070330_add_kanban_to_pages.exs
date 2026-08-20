defmodule Dran.Repo.Migrations.AddKanbanToPages do
  use Ecto.Migration

  def up do
    alter table(:pages) do
      add :kanban_status, :string
      add :priority, :string
      add :due_date, :date
      add :assignee, :string
    end
  end

  def down do
    alter table(:pages) do
      remove :kanban_status
      remove :priority
      remove :due_date
      remove :assignee
    end
  end
end
