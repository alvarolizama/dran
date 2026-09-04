defmodule Dran.Repo.Migrations.DropWorkflowsSummary do
  @moduledoc """
  Drop `workflows.summary` — campo dormido: sin UI, sin MCP, sin API que
  lo lea (la convención "one-liner" vive en goals/pages/tasks; el
  workflow tiene `body` para el brief completo). Se crea como
  nullable `:string` en create_plans_steps, así que el down la restaura
  sin riesgo de datos.
  """

  use Ecto.Migration

  def up do
    alter table(:workflows) do
      remove :summary, :string
    end
  end

  def down do
    alter table(:workflows) do
      add :summary, :string
    end
  end
end
