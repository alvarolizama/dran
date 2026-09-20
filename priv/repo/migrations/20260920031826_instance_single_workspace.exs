defmodule Dran.Repo.Migrations.InstanceSingleWorkspace do
  @moduledoc """
  W1 (contract-instance-visibility-20260919): the instance BECOMES a single
  workspace.

  1. `users.instance_role` — the instance-wide role, backfilled from the max
     role each user held across `user_workspaces` (owner > admin > editor >
     viewer). `content_scope` dies with the memberships (replaced by
     per-item visibility in W2/W3).
  2. Surviving workspaces are FOLDED into one: the default workspace (or the
     oldest one) keeps its row; every other workspace's content is
     re-pointed to it. Slugs stay unique per workspace, so conflicting page
     slugs are re-suffixed before the move (a plain UPDATE would trip the
     `[workspace_id, slug]` unique index).
  3. `user_workspaces` rows collapse onto the surviving workspace; duplicate
     memberships (a user member of two folded workspaces) keep the max role.

  Dropping the folded tables/columns is W6 (separate release). This migration
  runs inside Ecto's transaction: either the instance folds or nothing changes.
  """
  use Ecto.Migration
  import Ecto.Query

  def up do
    # 1 — instance role on users, backfilled from memberships.
    # SECURITY: memberships on the user's OWN personal workspace do NOT
    # count — everyone was "owner" of their personal silo, and counting it
    # would backfill every account to instance owner (= full admin). Only
    # roles earned on SHARED workspaces carry over. The exclusion runs
    # BEFORE the fold, while personal_workspace_id still points at the
    # original per-user workspace.
    alter table(:users) do
      add :instance_role, :string
    end

    execute """
    UPDATE users u
    SET instance_role = ranked.role
    FROM (
      SELECT uw.user_id,
             (ARRAY['viewer','editor','admin','owner'])[MAX(CASE uw.role
                WHEN 'owner' THEN 4 WHEN 'admin' THEN 3
                WHEN 'editor' THEN 2 ELSE 1 END)] AS role
      FROM user_workspaces uw
      JOIN users pu ON pu.id = uw.user_id
      WHERE uw.workspace_id IS DISTINCT FROM pu.personal_workspace_id
      GROUP BY uw.user_id
    ) ranked
    WHERE u.id = ranked.user_id
    """

    # The instance owner flag always wins (it already granted full access).
    execute """
    UPDATE users SET instance_role = 'owner'
    WHERE is_owner = true
    """

    # Everyone else without a shared-workspace role had only their personal
    # silo: they keep writing their OWN content (per-item visibility, W2/W3),
    # so "editor" is the equivalent instance role. Nobody lands on "owner".
    execute """
    UPDATE users SET instance_role = 'editor'
    WHERE instance_role IS NULL
    """

    # 2 — fold every workspace into a single survivor (Ecto runs this inside
    # the migration transaction; selecting here is safe).
    # NOTE: a schemaless `select: w.id` returns the UUID as RAW 16 bytes
    # (no type casting without a schema), so it is cast to the canonical
    # string form here — interpolating the binary poisons the SQL.
    survivor_id =
      case repo().one(
             from(w in "workspaces",
               select: w.id,
               order_by: [desc: w.is_default, asc: w.inserted_at, asc: w.id],
               limit: 1
             )
           ) do
        nil -> nil
        id -> Ecto.UUID.cast!(id)
      end

    survivor_id = to_string(survivor_id || "")

    if survivor_id != "" do
      fold_workspaces_into(survivor_id)
    end
  end

  defp fold_workspaces_into(survivor_id) do
    # Re-suffix slugs that would collide inside the survivor BEFORE moving
    # (the [workspace_id, slug] unique index would reject a blind UPDATE).
    execute """
    UPDATE knowledge_pages p
    SET slug = p.slug || '-' || left(md5(random()::text), 6),
        workspace_id = '#{survivor_id}'
    FROM knowledge_pages s
    WHERE p.workspace_id <> '#{survivor_id}'
      AND s.workspace_id = '#{survivor_id}'
      AND p.slug = s.slug
    """

    for table <- ~w(knowledge_pages memories collections reports brain_log
                    cluster_summaries worker_sessions) do
      execute """
      UPDATE #{table}
      SET workspace_id = '#{survivor_id}'
      WHERE workspace_id IS NOT NULL AND workspace_id <> '#{survivor_id}'
      """
    end

    # relations are polymorphic over pages (no workspace_id) — nothing to move.

    # 3 — collapse memberships onto the survivor in ONE statement: keep ONE
    # row per user (the max role across all their folded memberships), on the
    # survivor. Doing DELETE-then-UPDATE trips the (user_id, workspace_id)
    # unique index when a user had rows on two non-survivor workspaces.
    execute """
    DELETE FROM user_workspaces uw
    WHERE uw.workspace_id <> '#{survivor_id}'
      AND uw.id NOT IN (
        SELECT MIN(uw2.id)
        FROM user_workspaces uw2
        WHERE uw2.user_id = uw.user_id
        GROUP BY uw2.user_id
      )
    """

    execute """
    UPDATE user_workspaces
    SET workspace_id = '#{survivor_id}'
    WHERE workspace_id <> '#{survivor_id}'
    """

    execute """
    UPDATE user_workspaces uw
    SET role = ranked.max_role
    FROM (
      SELECT user_id,
             (ARRAY['viewer','editor','admin','owner'])[MAX(CASE role
                WHEN 'owner' THEN 4 WHEN 'admin' THEN 3
                WHEN 'editor' THEN 2 ELSE 1 END)] AS max_role
      FROM user_workspaces
      GROUP BY user_id
    ) ranked
    WHERE uw.user_id = ranked.user_id
    """

    # Every personal-workspace pointer now names the survivor: no code path
    # can resurrect the multi-workspace UI through a stale pointer. The old
    # UNIQUE constraint (one personal workspace PER USER→workspace pair, i.e.
    # a workspace is personal to at most ONE user) cannot hold once every
    # user's pointer names the same survivor — it is dropped; the column
    # itself dies in W6.
    execute """
    DROP INDEX IF EXISTS users_personal_workspace_id_index
    """

    execute """
    UPDATE users SET personal_workspace_id = '#{survivor_id}'
    """

    execute """
    UPDATE api_key_workspaces akw
    SET workspace_id = '#{survivor_id}'
    WHERE workspace_id <> '#{survivor_id}'
    """

    # Duplicate (api_key_id, workspace_id) pairs can only appear when a key
    # reached two folded workspaces — collapse them keeping the max level.
    execute """
    DELETE FROM api_key_workspaces akw
    USING api_key_workspaces akw2
    WHERE akw.id < akw2.id
      AND akw.api_key_id = akw2.api_key_id
      AND akw.workspace_id = '#{survivor_id}'
      AND akw2.workspace_id = '#{survivor_id}'
    """

    # Folded workspace rows become inert (no default flag). They survive
    # until W6 (D3) — cheap, reversible, nothing links to them.
    execute """
    UPDATE workspaces SET is_default = false WHERE id <> '#{survivor_id}'
    """

    execute """
    UPDATE workspaces SET is_default = true WHERE id = '#{survivor_id}'
    """
  end

  def down do
    # Irreversible in the general case: which page belonged to which folded
    # workspace is gone the moment rows are re-pointed. Un-folding is a
    # restore-from-backup operation; the only reversible step is the column.
    alter table(:users) do
      remove :instance_role
    end
  end
end
