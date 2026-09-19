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
        worker_max_pages: 25,
        semantic_threshold_short: 0.15,
        semantic_threshold_mid: 0.22,
        semantic_threshold_long: 0.28
      }

      changeset = Workspace.settings_changeset(%Workspace{}, attrs)
      assert changeset.valid?
    end

    test "worker_max_pages must be > 0 when present" do
      changeset = Workspace.settings_changeset(%Workspace{}, %{worker_max_pages: 0})
      refute changeset.valid?
      assert %{worker_max_pages: _} = errors_on(changeset)

      changeset = Workspace.settings_changeset(%Workspace{}, %{worker_max_pages: -5})
      refute changeset.valid?
      assert %{worker_max_pages: _} = errors_on(changeset)
    end

    test "worker_max_pages nil is allowed (use global default)" do
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
      assert Workspace.feature_enabled?(ws, "clusters")
      assert Workspace.feature_enabled?(ws, :clusters)
    end

    test "feature explicitly disabled → returns false" do
      ws = %Workspace{enabled_features: %{"clusters" => false}}
      refute Workspace.feature_enabled?(ws, "clusters")
    end

    test "feature explicitly enabled → returns true" do
      ws = %Workspace{enabled_features: %{"clusters" => true}}
      assert Workspace.feature_enabled?(ws, "clusters")
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
      ws = %Workspace{worker_max_pages: 25, semantic_threshold_short: 0.15}
      assert Workspace.get_tuning(ws, :worker_max_pages) == 25
      assert Workspace.get_tuning(ws, :semantic_threshold_short) == 0.15
    end

    test "falls back to Dran.Settings default when field is nil" do
      ws = %Workspace{worker_max_pages: nil, semantic_threshold_mid: nil}
      assert Workspace.get_tuning(ws, :worker_max_pages) == Settings.get("worker_max_pages")

      assert Workspace.get_tuning(ws, :semantic_threshold_mid) ==
               Settings.get("semantic_threshold_mid")
    end

    test "global settings override is picked up when workspace value is nil" do
      # Temporarily override the global setting
      original = Settings.get("worker_max_pages")
      Settings.put("worker_max_pages", 99)

      ws = %Workspace{worker_max_pages: nil}
      assert Workspace.get_tuning(ws, :worker_max_pages) == 99

      # Restore
      Settings.put("worker_max_pages", original)
    end
  end

  describe "workspace schema defaults" do
    test "new workspace has sensible defaults" do
      ws = %Workspace{}

      assert ws.is_default == false
      assert ws.visibility == "public"
      assert ws.enabled_features == %{}
      assert ws.workspace_page_types == []
      refute ws.semantic_threshold_short
      refute ws.semantic_threshold_mid
      refute ws.semantic_threshold_long
      refute ws.entity_linker_enabled
      refute ws.worker_max_pages
    end
  end

  describe "workspace_page_types — validation and normalization" do
    @recipe %{
      "slug" => "recipe",
      "label" => "Receta",
      "plural" => "Recetas",
      "path" => "recipes",
      "icon" => "hero-beaker",
      "color" => "amber",
      "meta_fields" => []
    }

    test "a well-formed ordered list is valid and preserved in order" do
      trip = %{@recipe | "slug" => "trip", "path" => "trips"}

      changeset =
        Workspace.settings_changeset(%Workspace{}, %{workspace_page_types: [@recipe, trip]})

      assert changeset.valid?
      slugs = Workspace.custom_page_type_slugs(%Workspace{workspace_page_types: [@recipe, trip]})
      assert slugs == ["recipe", "trip"]
    end

    test "icon/color default when omitted; label/plural default to the slug" do
      minimal = %{"slug" => "recipe", "path" => "recipes"}

      normalized = Workspace.normalize_page_types([minimal])
      assert [entry] = normalized
      assert entry["icon"] == "hero-document-text"
      assert entry["color"] == "#94A3B8"
      assert entry["meta_fields"] == []
    end

    test "a duplicated slug is rejected" do
      changeset =
        Workspace.settings_changeset(%Workspace{}, %{
          workspace_page_types: [@recipe, %{@recipe | "path" => "other"}]
        })

      refute changeset.valid?
      assert %{workspace_page_types: _} = errors_on(changeset)
    end

    test "a duplicated path is rejected" do
      changeset =
        Workspace.settings_changeset(%Workspace{}, %{
          workspace_page_types: [@recipe, %{@recipe | "slug" => "dish"}]
        })

      refute changeset.valid?
      assert %{workspace_page_types: _} = errors_on(changeset)
    end

    test "a slug colliding with a built-in type is rejected" do
      changeset =
        Workspace.settings_changeset(%Workspace{}, %{
          workspace_page_types: [%{@recipe | "slug" => "note"}]
        })

      refute changeset.valid?
      assert %{workspace_page_types: _} = errors_on(changeset)
    end

    test "slug format is enforced (lowercase identifier)" do
      changeset =
        Workspace.settings_changeset(%Workspace{}, %{
          workspace_page_types: [%{@recipe | "slug" => "Receta Mía"}]
        })

      refute changeset.valid?
      assert %{workspace_page_types: _} = errors_on(changeset)
    end

    test "slug and path are both required per entry" do
      for attrs <- [Map.delete(@recipe, "slug"), Map.delete(@recipe, "path")] do
        changeset = Workspace.settings_changeset(%Workspace{}, %{workspace_page_types: [attrs]})
        refute changeset.valid?
        assert %{workspace_page_types: _} = errors_on(changeset)
      end
    end

    test "the empty list (default) is valid" do
      assert Workspace.settings_changeset(%Workspace{}, %{workspace_page_types: []}).valid?
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
      Dran.Settings.put("worker_max_pages", 42)

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
        worker_max_pages = COALESCE(
          (SELECT (value->>'value')::integer FROM settings WHERE key = 'worker_max_pages'),
          ws.worker_max_pages)
      """)

      reloaded = Dran.Repo.get!(Workspace, ws.id)
      assert reloaded.semantic_threshold_short == 0.10
      assert reloaded.semantic_threshold_mid == 0.25
      assert reloaded.semantic_threshold_long == 0.30
      assert reloaded.entity_linker_enabled == false
      assert reloaded.worker_max_pages == 42
    end

    @tag :no_default_workspace
    test "columns stay NULL when no global setting row exists" do
      {:ok, ws} =
        Dran.Knowledge.create_workspace(%{name: "NoSettings", slug: "no-settings-ws"})

      # No settings rows for these keys in this sandbox → backfill leaves NULL
      reloaded = Dran.Repo.get!(Workspace, ws.id)
      refute reloaded.worker_max_pages
    end
  end

  describe "instance default — the is_default flag is the control" do
    @tag :no_default_workspace
    test "get_default_workspace/0 returns the flagged row, nil when none is flagged" do
      refute Dran.Knowledge.get_default_workspace()

      {:ok, ws} = Dran.Knowledge.create_workspace(%{name: "Flagged", slug: "flagged-ws"})
      {:ok, _} = Dran.Knowledge.update_workspace(ws, %{is_default: true})

      assert %Workspace{id: id} = Dran.Knowledge.get_default_workspace()
      assert id == ws.id
    end

    @tag :no_default_workspace
    test "flagging a second workspace clears the first (the flag is a switch)" do
      {:ok, first} = Dran.Knowledge.create_workspace(%{name: "First", slug: "first-ws"})
      {:ok, second} = Dran.Knowledge.create_workspace(%{name: "Second", slug: "second-ws"})

      {:ok, _} = Dran.Knowledge.update_workspace(first, %{is_default: true})
      {:ok, _} = Dran.Knowledge.update_workspace(second, %{is_default: true})

      refute Dran.Repo.get!(Workspace, first.id).is_default
      assert Dran.Repo.get!(Workspace, second.id).is_default
      assert Dran.Knowledge.get_default_workspace().id == second.id
    end

    @tag :no_default_workspace
    test "creating a workspace with is_default clears the previous default" do
      {:ok, first} = Dran.Knowledge.create_workspace(%{name: "Old", slug: "old-ws"})
      {:ok, _} = Dran.Knowledge.update_workspace(first, %{is_default: true})

      {:ok, created} =
        Dran.Knowledge.create_workspace(%{name: "New", slug: "new-ws", is_default: true})

      refute Dran.Repo.get!(Workspace, first.id).is_default
      assert Dran.Knowledge.get_default_workspace().id == created.id
    end

    @tag :no_default_workspace
    test "the flag wins over the legacy settings override" do
      Settings.put("default_workspace_slug", "legacy-slug")
      Settings.put("default_workspace_name", "Legacy Name")

      {:ok, flagged} =
        Dran.Knowledge.create_workspace(%{name: "Flagged", slug: "flagged-ws", is_default: true})

      assert Dran.Auth.default_workspace_slug() == flagged.slug
      assert Dran.Auth.default_workspace_name() == "Flagged"
    end

    @tag :no_default_workspace
    test "without a flagged workspace the legacy setting resolves, then falls back to personal" do
      assert Dran.Auth.default_workspace_slug() == "personal"
      assert Dran.Auth.default_workspace_name() == "Personal"
      refute Dran.Auth.default_workspace_configured?()

      Settings.put("default_workspace_slug", "legacy-slug")
      Settings.put("default_workspace_name", "Legacy Name")

      assert Dran.Auth.default_workspace_slug() == "legacy-slug"
      assert Dran.Auth.default_workspace_name() == "Legacy Name"
      assert Dran.Auth.default_workspace_configured?()
    end

    @tag :no_default_workspace
    test "a flagged workspace alone counts as a configured default" do
      refute Dran.Auth.default_workspace_configured?()

      {:ok, _} =
        Dran.Knowledge.create_workspace(%{name: "Only", slug: "only-ws", is_default: true})

      assert Dran.Auth.default_workspace_configured?()
    end
  end
end
