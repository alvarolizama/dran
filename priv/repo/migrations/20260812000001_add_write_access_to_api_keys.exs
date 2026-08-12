defmodule Dran.Repo.Migrations.AddWriteAccessToApiKeys do
  use Ecto.Migration

  def change do
    alter table(:api_keys) do
      add :write_access, :boolean, default: false, null: false
    end
  end
end
