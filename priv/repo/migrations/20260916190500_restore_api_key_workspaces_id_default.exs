defmodule Dran.Repo.Migrations.RestoreApiKeyWorkspacesIdDefault do
  use Ecto.Migration

  @moduledoc """
  Restores the `gen_random_uuid()` default on `api_key_workspaces.id`.

  `MakeApiKeysMultiWorkspace` declares the column as `primary_key: true, default:
  fragment("gen_random_uuid()")`, but databases created by loading the committed
  `priv/repo/structure.sql` dump never ran that migration and the dump was missing
  the default. Result: every `create_api_key/1` blew up with
  `null value in column "id" ... violates not-null constraint`, because the Ecto
  schema marks the primary key `read_after_writes: true` and relies on the
  database default.

  Migrations are the source of truth, so this converges any database (dev from a
  dump, CI, prod) without depending on how it was created. Idempotent: re-running
  sets the same default.
  """

  def up do
    execute("ALTER TABLE api_key_workspaces ALTER COLUMN id SET DEFAULT gen_random_uuid()")
  end

  def down do
    execute("ALTER TABLE api_key_workspaces ALTER COLUMN id DROP DEFAULT")
  end
end
