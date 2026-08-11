defmodule Dran.Repo.Migrations.AddIsEditorToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :is_editor, :boolean, default: false, null: false
    end
  end
end
