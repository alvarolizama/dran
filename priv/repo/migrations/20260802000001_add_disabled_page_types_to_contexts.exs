defmodule Dran.Repo.Migrations.AddDisabledPageTypesToContexts do
  use Ecto.Migration

  def change do
    alter table(:contexts) do
      add :disabled_page_types, {:array, :string}, null: false, default: []
    end
  end
end
