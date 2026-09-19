defmodule Dran.Repo.Migrations.MakeAllWorkspacesPrivate do
  use Ecto.Migration

  @moduledoc false

  # Every workspace is private from now on: access is granted per account
  # (Dran.Workspace.changeset/2 pins visibility to "private" on every write) or
  # by being the instance owner. The public, discoverable tier is gone.
  #
  # The column is kept — the API payload still carries it, and dropping it is a
  # separate, destructive step — so the rows that predate the rule have to be
  # brought in line with it. Without this they would keep reporting "public"
  # even though nothing grants access from it any more.
  def up do
    execute("UPDATE workspaces SET visibility = 'private' WHERE visibility <> 'private'")

    # The column default follows, so a row inserted outside the changeset (raw
    # SQL, a data fix) cannot come out public either.
    alter table(:workspaces) do
      modify :visibility, :string, default: "private", null: false
    end
  end

  # One-way on purpose: the previous public/private split cannot be
  # reconstructed, so there is no honest `down`.
  def down do
    :ok
  end
end
