defmodule Dran.Repo.Migrations.RenameAgentMaxPagesToWorkerMaxPages do
  use Ecto.Migration

  @moduledoc """
  Part of the agents → workers rename wave. The per-workspace tuning column
  `workspaces.agent_max_pages` becomes `worker_max_pages`, matching the
  schema field and the settings key of the same name. Runs BEFORE the main
  schema rename `20260903200000` (smaller timestamp) despite being a
  "second step" conceptually.
  """

  def up do
    rename table(:workspaces), :agent_max_pages, to: :worker_max_pages
  end

  def down do
    rename table(:workspaces), :worker_max_pages, to: :agent_max_pages
  end
end
