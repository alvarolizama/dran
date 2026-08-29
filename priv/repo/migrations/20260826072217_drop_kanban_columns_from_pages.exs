defmodule Dran.Repo.Migrations.DropKanbanColumnsFromPages do
  use Ecto.Migration

  @moduledoc """
  Drops the kanban columns from pages — they moved to the first-class
  tasks table (20260826060202) and the data migration
  (20260826061747) already carried every todo-note over.

  Also drops the meta expression indexes that referenced these columns
  (20260808061633 created kanban_status/assignee ones against meta — those
  stay; only column-dependent objects go).
  """

  def up do
    alter table(:pages) do
      remove :kanban_status
      remove :priority
      remove :due_date
      remove :assignee
    end
  end

  def down do
    alter table(:pages) do
      add :kanban_status, :string
      add :priority, :string
      add :due_date, :date
      add :assignee, :string
    end
  end
end
