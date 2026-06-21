defmodule Dran.Repo.Migrations.CreateExtensions do
  use Ecto.Migration

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS pg_trgm"
    execute "CREATE EXTENSION IF NOT EXISTS unaccent"
    execute "CREATE EXTENSION IF NOT EXISTS pgcrypto"
  end

  def down do
    execute "DROP EXTENSION IF EXISTS pgcrypto"
    execute "DROP EXTENSION IF EXISTS unaccent"
    execute "DROP EXTENSION IF EXISTS pg_trgm"
  end
end
