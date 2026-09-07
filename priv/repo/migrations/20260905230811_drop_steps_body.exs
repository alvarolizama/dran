defmodule Dran.Repo.Migrations.DropStepsBody do
  use Ecto.Migration

  # Contrato puro: `steps.body` duplicaba el rol del intent del contrato
  # (`render_brief/1` nunca lo leyó). El brief vive en meta["contract"],
  # congelado en run.contract_version al abrir la sesión.
  def change do
    alter table(:steps) do
      remove :body
    end
  end
end
