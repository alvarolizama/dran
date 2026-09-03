defmodule Dran.Repo.Migrations.RenameAgentMaxPagesToWorkerMaxPages do
  use Ecto.Migration

  @moduledoc """
  Second step of the agents → workers rename (schema: 20260903200000): the per-workspace
  tuning column `workspaces.agent_max_pages` becomes `worker_max_pages`,
  matching the schema field and the settings key of the same name.
  """

  def up do
    rename table(:workspaces), :agent_max_pages, to: :worker_max_pages
  end

  def down do
    rename table(:workspaces), :worker_max_pages, to: :agent_max_pages
  end
end
