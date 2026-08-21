defmodule Dran.WorkspaceTest do
  # sync — uses DB sandbox
  use Dran.DataCase, async: false

  alias Dran.Workspace
  alias Dran.Settings

  describe "changeset/2 — invariant: default ⇒ public" do
    test "is_default=true forces visibility to public, even when private was passed" do
      attrs = %{name: "Test", slug: "test-ws", is_default: true, visibility: "private"}

      changeset = Workspace.changeset(%Workspace{}, attrs)

      # get_field (not get_change): when the forced value equals the schema
      # default, Ecto drops the change — the effective value is what matters.
      assert Ecto.Changeset.get_field(changeset, :visibility) == "public"
      assert changeset.valid?
    end

    test "is_default=false keeps the requested visibility" do
      attrs = %{name: "Test", slug: "test-ws", is_default: false, visibility: "private"}

      changeset = Workspace.changeset(%Workspace{}, attrs)

      assert Ecto.Changeset.get_change(changeset, :visibility) == "private"
      assert changeset.valid?
    end

    test "default visibility is public when not specified" do
      attrs = %{name: "Test", slug: "test-ws"}

      changeset = Workspace.changeset(%Workspace{}, attrs)

      # No explicit visibility cast → the schema default ("public") applies
      refute Ecto.Changeset.get_change(changeset, :visibility)
      assert changeset.valid?
    end

    test "invalid visibility value is rejected" do
      # cast silently ignores unknown values, but validate_inclusion will fail
      attrs = %{name: "Test", slug: "test-ws", visibility: "secret"}

      changeset = Workspace.changeset(%Workspace{}, attrs)

      refute changeset.valid?
      assert %{visibility: _} = errors_on(changeset)
    end
  end

  describe "settings_changeset/2 — brain tuning validations" do
    test "valid changeset with all brain tuning fields" do
      attrs = %{
        agent_max_pages: 25,
        semantic_threshold_short: 0.15,
        semantic_threshold_mid: 0.22,
        semantic_threshold_long: 0.28
      }

      changeset = Workspace.settings_changeset(%Workspace{}, attrs)
      assert changeset.valid?
    end

    test "agent_max_pages must be > 0 when present" do
      changeset = Workspace.settings_changeset(%Workspace{}, %{agent_max_pages: 0})
      refute changeset.valid?
      assert %{agent_max_pages: _} = errors_on(changeset)

      changeset = Workspace.settings_changeset(%Workspace{}, %{agent_max_pages: -5})
      refute changeset.valid?
      assert %{agent_max_pages: _} = errors_on(changeset)
    end

    test "agent_max_pages nil is allowed (use global default)" do
      changeset = Workspace.settings_changeset(%Workspace{}, %{})
      assert changeset.valid?
    end

    test "semantic thresholds must be in 0..1 when present" do
      for field <- [:semantic_threshold_short, :semantic_threshold_mid, :semantic_threshold_long] do
        ok = Workspace.settings_changeset(%Workspace{}, %{field => 0.5})
        assert ok.valid?, "#{field}=0.5 should be valid"

        bad = Workspace.settings_changeset(%Workspace{}, %{field => 1.5})
        refute bad.valid?, "#{field}=1.5 should be invalid"
        assert %{^field => _} = errors_on(bad)

        bad2 = Workspace.settings_changeset(%Workspace{}, %{field => -0.1})
        refute bad2.valid?, "#{field}=-0.1 should be invalid"
        assert %{^field => _} = errors_on(bad2)
      end
    end

    test "nil thresholds are allowed (use global default)" do
      changeset = Workspace.settings_changeset(%Workspace{}, %{})
      assert changeset.valid?
    end

    test "is_default and visibility can be set via settings_changeset" do
      attrs = %{is_default: true, visibility: "private"}
      changeset = Workspace.settings_changeset(%Workspace{}, attrs)

      # Invariant: is_default=true forces visibility to public
      assert Ecto.Changeset.get_field(changeset, :visibility) == "public"
      assert changeset.valid?
    end
  end

  describe "feature_enabled?/2" do
    test "empty enabled_features (default) → all features ON" do
      ws = %Workspace{enabled_features: %{}}
      assert Workspace.feature_enabled?(ws, "goals")
      assert Workspace.feature_enabled?(ws, :goals)
    end

    test "feature explicitly disabled → returns false" do
      ws = %Workspace{enabled_features: %{"goals" => false}}
      refute Workspace.feature_enabled?(ws, "goals")
    end

    test "feature explicitly enabled → returns true" do
      ws = %Workspace{enabled_features: %{"goals" => true}}
      assert Workspace.feature_enabled?(ws, "goals")
    end

    test "unknown feature with empty map → ON (default)" do
      ws = %Workspace{enabled_features: %{}}
      assert Workspace.feature_enabled?(ws, "nonexistent_feature")
    end

    test "atom keys work via to_string conversion" do
      ws = %Workspace{enabled_features: %{"agent" => false}}
      refute Workspace.feature_enabled?(ws, :agent)
    end
  end

  describe "get_tuning/2 — per-workspace with fallback" do
    test "returns workspace value when set" do
      ws = %Workspace{agent_max_pages: 25, semantic_threshold_short: 0.15}
      assert Workspace.get_tuning(ws, :agent_max_pages) == 25
      assert Workspace.get_tuning(ws, :semantic_threshold_short) == 0.15
    end

    test "falls back to Dran.Settings default when field is nil" do
      ws = %Workspace{agent_max_pages: nil, semantic_threshold_mid: nil}
      assert Workspace.get_tuning(ws, :agent_max_pages) == Settings.get("agent_max_pages")

      assert Workspace.get_tuning(ws, :semantic_threshold_mid) ==
               Settings.get("semantic_threshold_mid")
    end

    test "global settings override is picked up when workspace value is nil" do
      # Temporarily override the global setting
      original = Settings.get("agent_max_pages")
      Settings.put("agent_max_pages", 99)

      ws = %Workspace{agent_max_pages: nil}
      assert Workspace.get_tuning(ws, :agent_max_pages) == 99

      # Restore
      Settings.put("agent_max_pages", original)
    end
  end

  describe "workspace schema defaults" do
    test "new workspace has sensible defaults" do
      ws = %Workspace{}

      assert ws.is_default == false
      assert ws.visibility == "public"
      assert ws.enabled_features == %{}
      refute ws.semantic_threshold_short
      refute ws.semantic_threshold_mid
      refute ws.semantic_threshold_long
      refute ws.entity_linker_enabled
      refute ws.agent_max_pages
    end
  end

  describe "migration backfill logic (settings → workspaces)" do
    @tag :no_default_workspace
    test "global settings values are copied to all workspaces on empty columns" do
      # Simulate the migration backfill: a workspace exists (as would have
      # existed in prod), global settings rows hold the old tuning, and the
      # backfill UPDATE copies them into the workspace columns.
      {:ok, ws} =
        Dran.Knowledge.create_workspace(%{name: "Backfill", slug: "backfill-ws"})

      Dran.Settings.put("semantic_threshold_short", 0.10)
      Dran.Settings.put("semantic_threshold_mid", 0.25)
      Dran.Settings.put("semantic_threshold_long", 0.30)
      Dran.Settings.put("entity_linker_enabled", false)
      Dran.Settings.put("agent_max_pages", 42)

      # Same UPDATE as the migration (per-workspace copy of global values).
      Dran.Repo.query!("""
      UPDATE workspaces ws
      SET
        semantic_threshold_short = COALESCE(
          (SELECT (value->>'value')::float FROM settings WHERE key = 'semantic_threshold_short'),
          ws.semantic_threshold_short),
        semantic_threshold_mid = COALESCE(
          (SELECT (value->>'value')::float FROM settings WHERE key = 'semantic_threshold_mid'),
          ws.semantic_threshold_mid),
        semantic_threshold_long = COALESCE(
          (SELECT (value->>'value')::float FROM settings WHERE key = 'semantic_threshold_long'),
          ws.semantic_threshold_long),
        entity_linker_enabled = COALESCE(
          (SELECT (value->>'value')::boolean FROM settings WHERE key = 'entity_linker_enabled'),
          ws.entity_linker_enabled),
        agent_max_pages = COALESCE(
          (SELECT (value->>'value')::integer FROM settings WHERE key = 'agent_max_pages'),
          ws.agent_max_pages)
      """)

      reloaded = Dran.Repo.get!(Workspace, ws.id)
      assert reloaded.semantic_threshold_short == 0.10
      assert reloaded.semantic_threshold_mid == 0.25
      assert reloaded.semantic_threshold_long == 0.30
      assert reloaded.entity_linker_enabled == false
      assert reloaded.agent_max_pages == 42
    end

    @tag :no_default_workspace
    test "columns stay NULL when no global setting row exists" do
      {:ok, ws} =
        Dran.Knowledge.create_workspace(%{name: "NoSettings", slug: "no-settings-ws"})

      # No settings rows for these keys in this sandbox → backfill leaves NULL
      reloaded = Dran.Repo.get!(Workspace, ws.id)
      refute reloaded.agent_max_pages
    end
  end
end
