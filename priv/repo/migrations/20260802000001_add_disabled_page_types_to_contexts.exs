defmodule Dran.Repo.Migrations.AddDisabledPageTypesToWorkspaces do
  use Ecto.Migration

  def change do
    alter table(:workspaces) do
      add :disabled_page_types, {:array, :string}, null: false, default: []
    end
  end
end
