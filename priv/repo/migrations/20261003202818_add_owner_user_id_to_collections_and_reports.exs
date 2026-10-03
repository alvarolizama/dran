defmodule Dran.Repo.Migrations.AddOwnerUserIdToCollectionsAndReports do
  @moduledoc """
  W2 (contract.md): collections and reports join the per-item read policy.

  Both tables declared `visibility` in 20260921000000 but never got an owner:
  their reads were unfiltered, so the column was a claim no query consulted.
  `owner_user_id` lands here with the same shape `memories` and
  `knowledge_pages` took in 20260916183343:

    * a row written by a person carries that person and is `private` unless
      its writer says otherwise;
    * a row written by a system producer (job output, curator output) stays
      NULL-owned — workspace-wide content, the documented meaning of a NULL
      owner (`Dran.Auth.resolve_owner_user_id/1`).

  ## The backfill (?03)

  Before this migration every reader read every row, and the new filter would
  hide a NULL-owned `private` row from every non-admin reader — a revocation
  nobody asked for. The backfill marks exactly those rows `public`, the same
  posture `VisibilityAndSharing` took for the same reason.

  Measured on this instance when the migration was written: 0 rows in
  `collections` and 0 in `reports` (8 `knowledge_pages`), so the statement is
  a no-op here — the decision is recorded, not inferred from the environment.
  """

  use Ecto.Migration

  @owned ~w(collections reports)

  def up do
    for table <- @owned do
      alter table(table) do
        add :owner_user_id, references(:users, on_delete: :nilify_all)
      end

      create index(table, [:workspace_id, :owner_user_id],
               name: :"#{table}_workspace_owner_index"
             )

      execute(
        """
        UPDATE #{table}
        SET visibility = 'public'
        WHERE owner_user_id IS NULL AND visibility = 'private'
        """,
        """
        UPDATE #{table}
        SET visibility = 'private'
        WHERE owner_user_id IS NULL AND visibility = 'public'
        """
      )
    end
  end

  def down do
    for table <- @owned do
      drop_if_exists index(table, [:workspace_id, :owner_user_id],
                       name: :"#{table}_workspace_owner_index"
                     )

      alter table(table) do
        remove :owner_user_id
      end
    end
  end
end
