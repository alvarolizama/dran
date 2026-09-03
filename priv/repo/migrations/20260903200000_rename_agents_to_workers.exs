defmodule Dran.Repo.Migrations.RenameAgentsToWorkers do
  use Ecto.Migration

  @moduledoc """
  Concept rename: the autonomous ReAct "agents" (curator, link_gardener,
  graph_rag) become "workers". Tables, columns and indexes are renamed in
  place; data is preserved (pure DDL renames, no row rewrites).

  * `agent_sessions` → `worker_sessions`
  * `agent_sessions.agent_type` → `worker_type`
  * `agent_steps` → `worker_steps`

  NOT renamed: `actors.kind = "agent"` (the actor identity kind — a global
  identity concept, deliberately kept).

  `workspaces.agent_max_pages` IS renamed to `worker_max_pages`, but by its
  own migration `20260903035725` (same wave, runs earlier — smaller
  timestamp), not here.

  Related renames done in the SAME wave (context for deployers):
  `config :agent_max_steps` → `:worker_max_steps` and env vars
  `AGENT_MAX_STEPS`/`AGENT_PER_STEP_TIMEOUT` → `WORKER_MAX_STEPS`/
  `WORKER_PER_STEP_TIMEOUT` (see config/runtime.exs) — UPDATE your
  environment when deploying, the old values are silently ignored.
  """

  def up do
    # worker_steps first: its FK references agent_sessions and follows the
    # parent rename automatically (FK constraint names are also renamed).
    rename table(:agent_steps), to: table(:worker_steps)

    rename table(:agent_sessions), to: table(:worker_sessions)
    rename table(:worker_sessions), :agent_type, to: :worker_type

    # Indexes are not renamed by rename/2 — do them explicitly.
    execute("ALTER INDEX agent_steps_session_id_index RENAME TO worker_steps_session_id_index")

    execute(
      "ALTER INDEX agent_steps_session_id_step_number_index RENAME TO worker_steps_session_id_step_number_index"
    )

    execute(
      "ALTER INDEX agent_sessions_agent_type_index RENAME TO worker_sessions_worker_type_index"
    )

    execute("ALTER INDEX agent_sessions_status_index RENAME TO worker_sessions_status_index")

    execute(
      "ALTER INDEX agent_sessions_workspace_id_index RENAME TO worker_sessions_workspace_id_index"
    )

    execute("""
    ALTER TABLE worker_sessions
      RENAME CONSTRAINT agent_sessions_workspace_id_fkey TO worker_sessions_workspace_id_fkey
    """)

    execute("""
    ALTER TABLE worker_steps
      RENAME CONSTRAINT agent_steps_session_id_fkey TO worker_steps_session_id_fkey
    """)

    execute("""
    ALTER TABLE worker_sessions
      RENAME CONSTRAINT agent_sessions_pkey TO worker_sessions_pkey
    """)

    execute("""
    ALTER TABLE worker_steps
      RENAME CONSTRAINT agent_steps_pkey TO worker_steps_pkey
    """)

    # NOT NULL constraints carry the old table name — rename them too so the
    # schema stays greppable/consistent. The worker_type one is tolerant:
    # fresh DBs name it agent_sessions_agent_type_not_null (column was
    # agent_type), while DBs migrated by earlier drafts of this migration
    # may carry agent_sessions_worker_type_not_null.
    execute(
      "ALTER TABLE worker_sessions RENAME CONSTRAINT agent_sessions_id_not_null TO worker_sessions_id_not_null"
    )

    execute(
      "ALTER TABLE worker_sessions RENAME CONSTRAINT agent_sessions_workspace_id_not_null TO worker_sessions_workspace_id_not_null"
    )

    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'agent_sessions_agent_type_not_null' AND conrelid = 'worker_sessions'::regclass) THEN
        ALTER TABLE worker_sessions RENAME CONSTRAINT agent_sessions_agent_type_not_null TO worker_sessions_worker_type_not_null;
      ELSIF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'agent_sessions_worker_type_not_null' AND conrelid = 'worker_sessions'::regclass) THEN
        ALTER TABLE worker_sessions RENAME CONSTRAINT agent_sessions_worker_type_not_null TO worker_sessions_worker_type_not_null;
      END IF;
    END $$;
    """)

    execute(
      "ALTER TABLE worker_sessions RENAME CONSTRAINT agent_sessions_input_not_null TO worker_sessions_input_not_null"
    )

    execute(
      "ALTER TABLE worker_sessions RENAME CONSTRAINT agent_sessions_status_not_null TO worker_sessions_status_not_null"
    )

    execute(
      "ALTER TABLE worker_sessions RENAME CONSTRAINT agent_sessions_inserted_at_not_null TO worker_sessions_inserted_at_not_null"
    )

    execute(
      "ALTER TABLE worker_sessions RENAME CONSTRAINT agent_sessions_updated_at_not_null TO worker_sessions_updated_at_not_null"
    )

    execute(
      "ALTER TABLE worker_steps RENAME CONSTRAINT agent_steps_id_not_null TO worker_steps_id_not_null"
    )

    execute(
      "ALTER TABLE worker_steps RENAME CONSTRAINT agent_steps_session_id_not_null TO worker_steps_session_id_not_null"
    )

    execute(
      "ALTER TABLE worker_steps RENAME CONSTRAINT agent_steps_step_number_not_null TO worker_steps_step_number_not_null"
    )

    execute(
      "ALTER TABLE worker_steps RENAME CONSTRAINT agent_steps_tool_name_not_null TO worker_steps_tool_name_not_null"
    )

    execute(
      "ALTER TABLE worker_steps RENAME CONSTRAINT agent_steps_inserted_at_not_null TO worker_steps_inserted_at_not_null"
    )

    execute(
      "ALTER TABLE worker_steps RENAME CONSTRAINT agent_steps_updated_at_not_null TO worker_steps_updated_at_not_null"
    )
  end

  def down do
    # Reverse of up — mirrors in opposite order.
    #
    # NOT NULL constraint renames are guarded: databases migrated by the
    # first version of this migration (which only renamed tables/columns/
    # indexes/pkey/fkey) still carry `agent_*_not_null` names, so renaming
    # them again would fail. DO blocks make the down idempotent-safe.
    execute("ALTER TABLE worker_steps RENAME CONSTRAINT worker_steps_pkey TO agent_steps_pkey")

    execute(
      "ALTER TABLE worker_sessions RENAME CONSTRAINT worker_sessions_pkey TO agent_sessions_pkey"
    )

    execute("""
    ALTER TABLE worker_steps
      RENAME CONSTRAINT worker_steps_session_id_fkey TO agent_steps_session_id_fkey
    """)

    execute("""
    ALTER TABLE worker_sessions
      RENAME CONSTRAINT worker_sessions_workspace_id_fkey TO agent_sessions_workspace_id_fkey
    """)

    execute(
      "ALTER INDEX worker_sessions_workspace_id_index RENAME TO agent_sessions_workspace_id_index"
    )

    execute("ALTER INDEX worker_sessions_status_index RENAME TO agent_sessions_status_index")

    execute(
      "ALTER INDEX worker_sessions_worker_type_index RENAME TO agent_sessions_agent_type_index"
    )

    execute(
      "ALTER INDEX worker_steps_session_id_step_number_index RENAME TO agent_steps_session_id_step_number_index"
    )

    execute("ALTER INDEX worker_steps_session_id_index RENAME TO agent_steps_session_id_index")

    execute("""
    DO $$
    DECLARE c record;
    BEGIN
      FOR c IN
        SELECT conname, conrelid::regclass AS tbl FROM pg_constraint
        WHERE conrelid IN ('worker_sessions'::regclass, 'worker_steps'::regclass)
          AND conname LIKE 'worker_%'
      LOOP
        EXECUTE format(
          'ALTER TABLE %s RENAME CONSTRAINT %I TO %s',
          c.tbl,
          c.conname,
          regexp_replace(c.conname, '^worker_', 'agent_')
        );
      END LOOP;
    END $$;
    """)

    rename table(:worker_sessions), :worker_type, to: :agent_type
    rename table(:worker_sessions), to: table(:agent_sessions)
    rename table(:worker_steps), to: table(:agent_steps)
  end
end
