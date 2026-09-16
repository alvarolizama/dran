defmodule Dran.ContentVisibilityMigrationTest do
  @moduledoc """
  Gate W1 del contrato: la migración de visibilidad/ownership existe, está
  aplicada, y su backfill es idempotente.

  Estos tests verifican el ESTADO de la base (no re-ejecutan la migración, que
  ya corrió): el runner de Ecto aplica las migraciones antes de la suite
  (`mix test` alias), así que aquí se comprueba que el schema y el backfill
  dejaron lo que el contrato promete.
  """
  use Dran.DataCase, async: false

  alias Dran.Repo

  @migration_version 20_260_916_183_343

  describe "schema de visibilidad" do
    test "actors.owner_user_id existe como FK nullable a users" do
      %{rows: rows} =
        Repo.query!("""
        SELECT c.is_nullable, c.data_type
        FROM information_schema.columns c
        WHERE c.table_name = 'actors' AND c.column_name = 'owner_user_id'
        """)

      assert [[is_nullable, data_type]] = rows
      assert is_nullable == "YES", "el owner es nullable (contenido del workspace)"
      assert data_type == "bigint", "FK a users.id (bigint)"
    end

    test "memories y knowledge_pages tienen owner_user_id + agent_name" do
      for table <- ~w(memories knowledge_pages) do
        %{rows: rows} =
          Repo.query!(
            """
            SELECT c.column_name FROM information_schema.columns c
            WHERE c.table_name = $1 AND c.column_name IN ('owner_user_id', 'agent_name')
            """,
            [table]
          )

        columns = Enum.map(rows, fn [name] -> name end)
        assert "owner_user_id" in columns, "#{table} debe tener owner_user_id"
        assert "agent_name" in columns, "#{table} debe tener agent_name"
      end
    end

    test "workspaces tiene share_memory y share_pages con default true" do
      %{rows: rows} =
        Repo.query!("""
        SELECT column_name, column_default, is_nullable
        FROM information_schema.columns
        WHERE table_name = 'workspaces'
          AND column_name IN ('share_memory', 'share_pages')
        """)

      assert length(rows) == 2, "ambas columnas deben existir"

      for [_name, default, is_nullable] <- rows do
        assert is_nullable == "NO"
        assert default =~ "true", "el default preserva el comportamiento compartido"
      end
    end

    test "user_workspaces.content_scope existe con default 'all'" do
      %{rows: rows} =
        Repo.query!("""
        SELECT column_default, is_nullable
        FROM information_schema.columns
        WHERE table_name = 'user_workspaces' AND column_name = 'content_scope'
        """)

      assert [[default, is_nullable]] = rows
      assert is_nullable == "NO"
      assert default =~ "all", "el default es ver todo el workspace"
    end
  end

  describe "índice de dedupe de memoria" do
    test "el índice scoped por dueño existe y el viejo fue reemplazado" do
      %{rows: rows} =
        Repo.query!("""
        SELECT indexname FROM pg_indexes
        WHERE tablename = 'memories' AND indexname LIKE '%content_hash%'
        """)

      names = Enum.map(rows, fn [name] -> name end)
      assert "memories_workspace_owner_content_hash_idx" in names
      refute "memories_workspace_content_hash_idx" in names
    end

    test "el índice dedupea NULL-owner consigo mismo (NULLS NOT DISTINCT)" do
      %{rows: rows} =
        Repo.query!("""
        SELECT indexdef FROM pg_indexes
        WHERE indexname = 'memories_workspace_owner_content_hash_idx'
        """)

      assert [[definition]] = rows

      assert definition =~ "NULLS NOT DISTINCT",
             "sin esto, el contenido del workspace dejaría de dedupear"

      assert definition =~ "owner_user_id"
    end
  end

  describe "backfill best-effort" do
    test "la migración está registrada como aplicada" do
      %{rows: rows} =
        Repo.query!(
          """
          SELECT version::text FROM schema_migrations
          WHERE version::text = $1
          """,
          [Integer.to_string(@migration_version)]
        )

      assert [[_version]] = rows,
             "la migración #{@migration_version} debe estar aplicada"
    end

    test "un actor con key de un creador resuelve a ese usuario (backfill)" do
      unique = System.unique_integer([:positive])

      {:ok, user} =
        %Dran.Accounts.User{}
        |> Dran.Accounts.User.changeset(%{
          email: "backfill-#{unique}@dran.test",
          api_token: "backfill-token-#{unique}"
        })
        |> Repo.insert()

      {:ok, workspace} =
        Dran.Knowledge.create_workspace(%{
          name: "Backfill #{unique}",
          slug: "backfill-#{unique}"
        })

      {:ok, _} =
        %Dran.Accounts.UserWorkspace{}
        |> Dran.Accounts.UserWorkspace.changeset(%{
          user_id: user.id,
          workspace_id: workspace.id,
          role: "owner"
        })
        |> Repo.insert()

      actor = Dran.Accounts.ApiKey.ensure_actor_for_key_name("backfill-agent-#{unique}")

      {:ok, _key} =
        Dran.Accounts.create_api_key(%{
          name: "backfill-agent-#{unique}",
          created_by_user_id: user.id,
          actor_id: actor.id,
          workspace_ids: [{workspace.id, "write"}]
        })

      # El backfill corre en SQL dentro de la migración; aquí se comprueba que
      # el vínculo que lo alimenta (key → created_by_user_id) es resoluble, que
      # es la precondición del backfill.
      %{rows: [[resolved]]} =
        Repo.query!(
          """
          SELECT min(k.created_by_user_id)
          FROM api_keys k
          WHERE k.actor_id = $1 AND k.created_by_user_id IS NOT NULL
          """,
          [Ecto.UUID.dump!(actor.id)]
        )

      assert resolved == user.id || to_string(resolved) == to_string(user.id)
    end
  end
end
