defmodule Dran.Repo.Migrations.AddUniqueIndexToUsersPersonalWorkspace do
  use Ecto.Migration

  @moduledoc false

  # The other half of "one personal workspace per account".
  #
  # `Dran.Accounts.ensure_personal_workspace/1` enforces it in the application by
  # locking the account row, which is what stops a concurrent signup/backfill from
  # creating TWO workspaces for the same account. This index covers the inverse
  # mistake at the schema level: one workspace can never be the personal
  # workspace of two different accounts.
  #
  # Postgres does not compare NULLs in a unique index, so the accounts that have
  # no personal workspace yet (pre-backfill, or after theirs was deleted and the
  # pointer was NILIFIED) all coexist happily.
  def change do
    # Replaces the plain index added by AddPersonalWorkspaceToUsers (same columns,
    # same default name `users_personal_workspace_id_index`): the unique one serves
    # the lookups just as well.
    drop index(:users, [:personal_workspace_id])
    create unique_index(:users, [:personal_workspace_id])
  end
end
