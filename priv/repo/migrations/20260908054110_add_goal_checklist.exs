defmodule Dran.Repo.Migrations.AddGoalChecklist do
  @moduledoc """
  Add `checklist` to goals — lightweight sub-items (`[%{"text", "done"}]`,
  same shape the removed tasks table used). Replaces task-level checklists
  as the goal's own progress list.
  """

  use Ecto.Migration

  def change do
    alter table(:goals) do
      add :checklist, :jsonb, default: "[]", null: false
    end
  end
end
