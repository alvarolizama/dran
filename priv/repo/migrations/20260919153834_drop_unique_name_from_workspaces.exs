defmodule Dran.Repo.Migrations.DropUniqueNameFromWorkspaces do
  use Ecto.Migration

  @moduledoc false

  # `workspaces.name` stops being unique. It dates from when a workspace was an
  # instance-level "context" and its name was its identity everywhere; now the
  # name is a LABEL for humans and the identity is the slug (which DOES stay
  # unique, because it is the URL segment: /:workspace_slug/...).
  #
  # The global index was a trap: it made two workspaces called "Personal"
  # impossible, so a second person named Alice (or the same person starting a
  # second project) got "has already been taken" on a field that only exists to
  # be read.
  def up do
    drop unique_index(:workspaces, [:name])
  end

  # Recreating the index requires the names to be distinct again, which they may
  # no longer be — that is the point of the migration. `up` is the honest
  # direction; a rollback has to deal with the duplicates by hand first.
  def down do
    create unique_index(:workspaces, [:name])
  end
end
