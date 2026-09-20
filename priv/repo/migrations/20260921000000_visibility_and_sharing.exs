defmodule Dran.Repo.Migrations.VisibilityAndSharing do
  @moduledoc """
  W2 (contract-instance-visibility-20260919): per-item visibility + sharing.

  1. `visibility` on every shareable content table (`private` | `public` |
     `shared`), default `private`. Backfill: existing rows become `public` —
     today `share_pages`/`share_memory` default to true (every member reads
     everything), so `private` would revoke access on deploy (D5).
  2. `user_groups` + `user_group_members`: named groups for share-with-group.
  3. `content_shares`: polymorphic grant table. Exactly one of
     (`user_id`, `group_id`) is non-NULL (CHECK); unique per
     (resource_type, resource_id, grant) so re-sharing is idempotent.

  Dropping nothing — the workspace fold already happened in W1.
  """

  use Ecto.Migration

  @shareable ~w(knowledge_pages memories collections reports)

  def up do
    # 1 — visibility column + backfill + partial index for the public reads.
    for table <- @shareable do
      alter table(table) do
        add :visibility, :string
      end

      execute "UPDATE #{table} SET visibility = 'public' WHERE visibility IS NULL",
              "UPDATE #{table} SET visibility = NULL"

      alter table(table) do
        modify :visibility, :string, null: false, default: "private"
      end

      create index(table, [:visibility], where: "visibility = 'public'")
    end

    # 2 — user groups.
    create table(:user_groups) do
      add :name, :string, null: false
      add :slug, :string, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:user_groups, [:slug])

    create table(:user_group_members) do
      add :user_group_id, references(:user_groups, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:user_group_members, [:user_group_id, :user_id])
    create index(:user_group_members, [:user_id])

    # 3 — shares. resource_type: "page" | "memory" | "collection" | "report";
    # resource_id is the row UUID. Read-only grants (write stays with the
    # owner, ?03): no role column by design.
    create table(:content_shares, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :resource_type, :string, null: false
      add :resource_id, :binary_id, null: false
      # grant target: exactly one set (CHECK below)
      add :user_id, references(:users, on_delete: :delete_all)
      add :user_group_id, references(:user_groups, on_delete: :delete_all)

      timestamps(type: :utc_datetime, updated_at: false)
    end

    # Exactly one grant target per share row.
    execute """
            ALTER TABLE content_shares
            ADD CONSTRAINT content_shares_exactly_one_target CHECK (
              (user_id IS NOT NULL AND user_group_id IS NULL) OR
              (user_id IS NULL AND user_group_id IS NOT NULL)
            )
            """,
            "ALTER TABLE content_shares DROP CONSTRAINT content_shares_exactly_one_target"

    create unique_index(:content_shares, [:resource_type, :resource_id, :user_id],
             where: "user_id IS NOT NULL"
           )

    create unique_index(:content_shares, [:resource_type, :resource_id, :user_group_id],
             where: "user_group_id IS NOT NULL"
           )

    create index(:content_shares, [:user_id])
    create index(:content_shares, [:user_group_id])
    create index(:content_shares, [:resource_type, :resource_id])
  end

  def down do
    drop table(:content_shares)
    drop table(:user_group_members)
    drop table(:user_groups)

    for table <- @shareable do
      alter table(table) do
        remove :visibility
      end
    end
  end
end
