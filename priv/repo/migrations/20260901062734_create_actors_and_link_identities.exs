defmodule Dran.Repo.Migrations.CreateActorsAndLinkIdentities do
  use Ecto.Migration

  @moduledoc """
  Global actor model: instance-wide identities (kind: user | agent | system).

  * `actors` — the identity registry. One row per human user, agent, or
    internal system producer. NOT workspace-scoped: an actor is who someone
    *is*; permissions stay in `api_key_workspaces` and user-workspace roles.
  * `api_keys.actor_id` — a key is a credential attached to an actor.
    Backfilled 1:1 from `api_keys.name` (the old convention: key name IS the
    agent identity), then made NOT NULL.
  * `users.actor_id` — every human user gets a kind=user actor (backfilled
    from email). Nullable: users may be created before an actor exists.

  System actors (`system`, `entity_linker`, `jobs`, `automation`) are seeded
  here and re-upserted on boot by `Dran.Actors.ensure_system_actors!/0`
  (idempotent). They are managed in code, never in the CRUD.

  Old string attribution columns (`owner`/`created_by`) stay in place —
  they keep their data; the resolution layer switches to actors in the
  application layer.
  """

  @system_actors [
    %{name: "system", display_name: "System"},
    %{name: "entity_linker", display_name: "Entity Linker"},
    %{name: "jobs", display_name: "Scheduled Jobs"},
    %{name: "automation", display_name: "Task Automation"}
  ]

  def up do
    create table(:actors, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :name, :string, null: false
      add :kind, :string, null: false, default: "agent"
      add :display_name, :string
      add :host, :string

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:actors, [:name], name: :actors_name_index)
    create index(:actors, [:kind], name: :actors_kind_index)

    # ── Seed system actors (idempotent) ──
    for actor <- @system_actors do
      execute("""
      INSERT INTO actors (id, name, kind, display_name, inserted_at)
      VALUES (gen_random_uuid(), '#{actor.name}', 'system', '#{actor.display_name}', now())
      ON CONFLICT (name) DO NOTHING
      """)
    end

    # ── api_keys -> actor ──
    alter table(:api_keys) do
      add :actor_id, references(:actors, type: :binary_id, on_delete: :restrict)
    end

    # Backfill: one kind=agent actor per key name that doesn't already exist
    # (a collision with a system/system-named actor reuses that actor).
    execute("""
    INSERT INTO actors (id, name, kind, inserted_at)
    SELECT gen_random_uuid(), k.name, 'agent', now()
    FROM api_keys k
    WHERE k.name IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM actors a WHERE a.name = k.name)
    """)

    execute("""
    UPDATE api_keys
    SET actor_id = (SELECT id FROM actors WHERE name = api_keys.name)
    WHERE actor_id IS NULL
    """)

    execute("ALTER TABLE api_keys ALTER COLUMN actor_id SET NOT NULL")
    create index(:api_keys, [:actor_id], name: :api_keys_actor_id_index)

    # ── users -> actor ──
    alter table(:users) do
      add :actor_id, references(:actors, type: :binary_id, on_delete: :nilify_all)
    end

    execute("""
    INSERT INTO actors (id, name, kind, inserted_at)
    SELECT gen_random_uuid(), u.email, 'user', now()
    FROM users u
    WHERE u.email IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM actors a WHERE a.name = u.email)
    """)

    execute("""
    UPDATE users
    SET actor_id = (SELECT id FROM actors WHERE name = users.email)
    WHERE actor_id IS NULL
    """)

    create index(:users, [:actor_id], name: :users_actor_id_index)

    # ── Legacy attribution backfill ──
    # "alvaro" / "admin" come from the legacy DRAN_API_TOKEN path (historical
    # pages/tasks attributed to the literal admin token). Register them as
    # kind=agent actors so historical created_by values resolve; "admin"
    # keeps resolving via the legacy-token branch in Dran.Auth as well.
    execute("""
    INSERT INTO actors (id, name, kind, inserted_at)
    SELECT gen_random_uuid(), p.created_by, 'agent', now()
    FROM pages p
    WHERE p.created_by IS NOT NULL
      AND p.created_by NOT IN ('system')
      AND NOT EXISTS (SELECT 1 FROM actors a WHERE a.name = p.created_by)
    GROUP BY p.created_by
    """)
  end

  def down do
    drop_if_exists(index(:users, [:actor_id], name: :users_actor_id_index))

    alter table(:users) do
      remove :actor_id
    end

    drop_if_exists(index(:api_keys, [:actor_id], name: :api_keys_actor_id_index))

    alter table(:api_keys) do
      remove :actor_id
    end

    drop table(:actors)
  end
end
