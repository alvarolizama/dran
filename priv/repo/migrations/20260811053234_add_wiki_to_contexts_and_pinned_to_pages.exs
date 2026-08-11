defmodule Dran.Repo.Migrations.AddWikiToContextsAndPinnedToPages do
  use Ecto.Migration

  def change do
    alter table(:contexts) do
      add :wiki_enabled, :boolean, default: false, null: false
      add :wiki_description, :text
    end

    alter table(:pages) do
      add :pinned, :boolean, default: false, null: false
    end
  end
end
