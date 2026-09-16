defmodule Dran.Repo.Migrations.AddReadVisibilityAndOwnership do
  use Ecto.Migration

  @moduledoc """
  Read visibility + ownership attribution (contract: Visibilidad por dueño).

  Adds the ownership link user→agent and the per-workspace sharing policy that
  the read path needs. WRITE rules are unchanged.

  * `actors.owner_user_id` — nullable FK to `users`. The user that owns the
    agent represented by this actor. Backfilled best-effort from
    actor → api_keys → created_by_user_id, plus the 1:1 user actor.
  * `memories.owner_user_id` / `knowledge_pages.owner_user_id` — a snapshot of
    the owner user at write time (server-side). NULL means "workspace-wide
    content" (system/producers).
  * `memories.agent_name` / `knowledge_pages.agent_name` — the Hermes profile
    name that produced the write (from `X-Hermes-Agent`).
  * `workspaces.share_memory` / `share_pages` — per-workspace read policy.
    `true` (default) = the whole workspace reads it; `false` = isolated.
  * `user_workspaces.content_scope` — per-user preference per workspace:
    `"all"` (default) or `"own"` (only mine, including my agents' content).
  * Dedupe of memory moves from `UNIQUE(workspace_id, content_hash)` to
    `UNIQUE(workspace_id, owner_user_id, content_hash) NULLS NOT DISTINCT`
    so two owners may hold the same fact in an isolated workspace while
    workspace-wide (NULL owner) content still dedupes against itself.
    The shared-workspace "dedupe is global" behaviour is enforced in the
    application layer (it queries by workspace+hash before inserting).

  Idempotent: every backfill is a guarded UPDATE/INSERT that converges when
  re-run (posture of `CreateActorsAndLinkIdentities`).
  """

  def up do
    # ── actors: ownership link ────────────────────────────────────────────────
    alter table(:actors) do
      add :owner_user_id, references(:users, on_delete: :nilify_all)
    end

    create index(:actors, [:owner_user_id], name: :actors_owner_user_id_index)

    # Best-effort: an agent actor is owned by the user who created the keys
    # bound to it. Several keys may point at one actor — the oldest creator
    # wins (min), so the result is stable across re-runs.
    execute("""
    UPDATE actors a
    SET owner_user_id = src.user_id
    FROM (
      SELECT k.actor_id, min(k.created_by_user_id) AS user_id
      FROM api_keys k
      WHERE k.actor_id IS NOT NULL AND k.created_by_user_id IS NOT NULL
      GROUP BY k.actor_id
    ) src
    WHERE a.id = src.actor_id AND a.owner_user_id IS DISTINCT FROM src.user_id
    """)

    # A kind=user actor belongs to that user, always (strongest signal).
    execute("""
    UPDATE actors a
    SET owner_user_id = u.id
    FROM users u
    WHERE u.actor_id = a.id AND a.owner_user_id IS DISTINCT FROM u.id
    """)

    # ── memory + knowledge: owner snapshot + agent name ───────────────────────
    for table <- ["memories", "knowledge_pages"] do
      alter table(table) do
        add :owner_user_id, references(:users, on_delete: :nilify_all)
        add :agent_name, :string
      end

      create index(table, [:workspace_id, :owner_user_id],
               name: :"#{table}_workspace_owner_index"
             )

      # Legacy string attribution (`created_by`) resolves to an actor name;
      # register the missing ones first (same posture as the actors migration).
      execute("""
      INSERT INTO actors (id, name, kind, inserted_at)
      SELECT gen_random_uuid(), t.created_by, 'agent', now()
      FROM #{table} t
      WHERE t.created_by IS NOT NULL
        AND t.created_by NOT IN ('system')
        AND NOT EXISTS (SELECT 1 FROM actors a WHERE a.name = t.created_by)
      GROUP BY t.created_by
      """)

      # Snapshot the owner from the resolved actor. Rows whose actor has no
      # owner (system producers, unresolvable legacy) stay NULL = workspace
      # content, and are re-attempted on the next run once the actor is owned.
      execute("""
      UPDATE #{table} t
      SET owner_user_id = a.owner_user_id,
          agent_name = coalesce(t.agent_name, t.created_by)
      FROM actors a
      WHERE a.name = t.created_by
        AND a.owner_user_id IS NOT NULL
        AND t.owner_user_id IS NULL
      """)
    end

    # ── workspace read policy ─────────────────────────────────────────────────
    alter table(:workspaces) do
      add :share_memory, :boolean, null: false, default: true
      add :share_pages, :boolean, null: false, default: true
    end

    # ── per-user content preference ───────────────────────────────────────────
    alter table(:user_workspaces) do
      add :content_scope, :string, null: false, default: "all"
    end

    # ── memory dedupe: scoped by owner ────────────────────────────────────────
    # NULLS NOT DISTINCT (PG >= 15): two NULL-owner rows with the same hash
    # still collide, so workspace-wide content keeps deduping itself.
    execute("DROP INDEX IF EXISTS memories_workspace_content_hash_idx")

    execute("""
    CREATE UNIQUE INDEX memories_workspace_owner_content_hash_idx
    ON memories (workspace_id, owner_user_id, content_hash) NULLS NOT DISTINCT
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS memories_workspace_owner_content_hash_idx")

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS memories_workspace_content_hash_idx
    ON memories (workspace_id, content_hash)
    """)

    alter table(:user_workspaces) do
      remove :content_scope
    end

    alter table(:workspaces) do
      remove :share_memory
      remove :share_pages
    end

    for table <- ["memories", "knowledge_pages"] do
      drop_if_exists index(table, [:workspace_id, :owner_user_id],
                       name: :"#{table}_workspace_owner_index"
                     )

      alter table(table) do
        remove :owner_user_id
        remove :agent_name
      end
    end

    drop_if_exists index(:actors, [:owner_user_id], name: :actors_owner_user_id_index)

    alter table(:actors) do
      remove :owner_user_id
    end
  end
end
