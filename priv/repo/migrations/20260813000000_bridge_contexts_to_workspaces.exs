defmodule Dran.Repo.Migrations.BridgeContextsToWorkspaces do
  @moduledoc """
  Bridge for databases bootstrapped BEFORE the contexts→workspaces rename
  (commit 81cb10b rewrote the early migrations in-place instead of adding a
  rename migration, so a DB created from the pre-rename schema has `contexts`
  + `context_id` columns and stalls at migration 20260812000001 with
  `relation "workspaces" does not exist`).

  Runs BEFORE 20260819165200 (the first migration that references
  `workspaces`) and is a no-op when the schema was bootstrapped from the
  post-rename migrations (fresh databases already create `:workspaces` in
  001_create_contexts.exs).

  What it renames (only when the legacy schema is detected):

    * tables: contexts → workspaces, user_contexts → user_workspaces
    * columns: context_id → workspace_id on pages, brain_log,
      agent_sessions, chat_sessions, community_summaries, api_keys and
      user_workspaces; users.default_context_slug → default_workspace_slug
    * indexes whose names encode the old table/column names (Postgres
      renames tables/columns but NOT the index names)

  Every step is conditional on the legacy object actually existing: the
  legacy timeline dropped `chat_sessions` (20260718021654), so its
  context_id rename must be skipped there.

  `ALTER TABLE ... RENAME` takes an AccessExclusiveLock. We set a 5s
  lock_timeout so the migration fails fast (deploy aborts, Coolify rolls
  back, retry) instead of piling up behind live traffic from a container
  that is still serving during the deploy.

  The `down` is a no-op by design: reversing the bridge on a fresh database
  (which never had `contexts`) would corrupt it, and legacy databases that
  already consumed the bridge must keep moving forward.
  """
  use Ecto.Migration

  def up do
    execute "SET LOCAL lock_timeout = '5s'"

    execute """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public' AND table_name = 'contexts'
      ) THEN
        RAISE NOTICE 'bridge: no legacy contexts table, nothing to do';
        RETURN;
      END IF;

      RAISE NOTICE 'bridge: legacy schema detected, renaming contexts → workspaces';

      -- Tables (pkeys/constraints follow the table rename)
      ALTER TABLE contexts RENAME TO workspaces;
      ALTER TABLE IF EXISTS user_contexts RENAME TO user_workspaces;

      -- Columns: context_id → workspace_id on every referencing table that
      -- still exists in the legacy schema (chat_sessions was dropped by
      -- 20260718021654 in the pre-rename timeline).
      IF EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_name = 'pages' AND column_name = 'context_id') THEN
        ALTER TABLE pages RENAME COLUMN context_id TO workspace_id;
      END IF;

      IF EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_name = 'brain_log' AND column_name = 'context_id') THEN
        ALTER TABLE brain_log RENAME COLUMN context_id TO workspace_id;
      END IF;

      IF EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_name = 'agent_sessions' AND column_name = 'context_id') THEN
        ALTER TABLE agent_sessions RENAME COLUMN context_id TO workspace_id;
      END IF;

      IF EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_name = 'chat_sessions' AND column_name = 'context_id') THEN
        ALTER TABLE chat_sessions RENAME COLUMN context_id TO workspace_id;
      END IF;

      IF EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_name = 'community_summaries' AND column_name = 'context_id') THEN
        ALTER TABLE community_summaries RENAME COLUMN context_id TO workspace_id;
      END IF;

      IF EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_name = 'api_keys' AND column_name = 'context_id') THEN
        ALTER TABLE api_keys RENAME COLUMN context_id TO workspace_id;
      END IF;

      IF EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_name = 'user_workspaces' AND column_name = 'context_id') THEN
        ALTER TABLE user_workspaces RENAME COLUMN context_id TO workspace_id;
      END IF;

      IF EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_name = 'users' AND column_name = 'default_context_slug') THEN
        ALTER TABLE users RENAME COLUMN default_context_slug TO default_workspace_slug;
      END IF;

      -- Index names that encode the old table/column names.
      -- Indexes whose name is stable across the rename (pages_ctx_type_idx,
      -- pages_ctx_type_archived_idx, pages_context_updated_at_idx,
      -- brain_log_ctx_inserted_at_idx) need no action.
      ALTER INDEX IF EXISTS contexts_name_index RENAME TO workspaces_name_index;
      ALTER INDEX IF EXISTS contexts_slug_index RENAME TO workspaces_slug_index;
      ALTER INDEX IF EXISTS pages_context_id_slug_index RENAME TO pages_workspace_id_slug_index;
      ALTER INDEX IF EXISTS pages_slug_idx RENAME TO pages_workspace_id_slug_idx;
      ALTER INDEX IF EXISTS pages_context_id_archived_index RENAME TO pages_workspace_id_archived_index;
      ALTER INDEX IF EXISTS brain_log_context_id_index RENAME TO brain_log_workspace_id_index;
      ALTER INDEX IF EXISTS agent_sessions_context_id_index RENAME TO agent_sessions_workspace_id_index;
      ALTER INDEX IF EXISTS chat_sessions_context_id_user_index RENAME TO chat_sessions_workspace_id_user_index;
      ALTER INDEX IF EXISTS api_keys_context_id_index RENAME TO api_keys_workspace_id_index;
      ALTER INDEX IF EXISTS user_contexts_user_id_context_id_index RENAME TO user_workspaces_user_id_workspace_id_index;
      ALTER INDEX IF EXISTS community_summaries_context_id_community_id_index RENAME TO community_summaries_workspace_id_community_id_index;
      ALTER INDEX IF EXISTS community_summaries_context_id_index RENAME TO community_summaries_workspace_id_index;
    END $$;
    """
  end

  def down do
    # Intentional no-op — see moduledoc.
    :ok
  end
end
