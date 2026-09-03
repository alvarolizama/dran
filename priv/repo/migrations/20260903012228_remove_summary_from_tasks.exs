defmodule Dran.Repo.Migrations.RemoveSummaryFromTasks do
  @moduledoc """
  Drop `tasks.summary` — dead weight. The field existed in the schema but
  no UI, MCP tool, or pipeline ever read or wrote it.
  """

  use Ecto.Migration

  def up do
    alter table(:tasks) do
      remove :summary, :text
    end
  end

  def down do
    alter table(:tasks) do
      add :summary, :text
    end
  end
end
