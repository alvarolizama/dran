defmodule DranWeb.SettingsLiveTest do
  use DranWeb.ConnCase, async: false

  import Ecto.Query

  alias Dran.Accounts
  alias Dran.Knowledge

  # Gettext wrapper — the app default locale is "es", so assertions must
  # match the translated strings, not the English msgids.
  defp t(msgid), do: Gettext.gettext(DranWeb.Gettext, msgid)

  setup %{conn: conn} do
    # Create (or fetch) an admin user whose email matches the session value the
    # router's require_admin plug looks up. The /settings route is admin-only.
    case Accounts.get_user_by_email("test_user") do
      nil ->
        {:ok, _user} =
          Accounts.create_user(%{email: "test_user", name: "Test Admin", is_owner: true})

      _ ->
        :ok
    end

    # Log in — init_test_session is needed because ConnCase doesn't pipe
    # through the browser pipeline that Auth expects.
    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user, "test_user")
      |> Plug.Conn.put_session(:workspace_slug, "personal")
      |> Plug.Conn.put_session(:is_owner, true)

    {:ok, conn: conn}
  end

  # ── W3: /settings/api-keys — gestión de keys sin CRUD de actores ───────────

  describe "api keys tab (W3)" do
    test "GET /settings/api-keys responde 200 y la ruta vieja /settings/agents no existe (P6)", %{
      conn: conn
    } do
      {:ok, view, html} = live(conn, ~p"/settings/api-keys")

      assert html =~ t("API keys")
      assert html =~ ~s(id="api-keys-tab")

      # La ruta vieja ya no está en la tabla de rutas (P6): ninguna entrada
      # declara el path literal "/settings/agents".
      paths = Enum.map(DranWeb.Router.__routes__(), & &1.path)

      refute "/settings/agents" in paths
      assert "/settings/api-keys" in paths

      # Y pedirla no renderiza la página: cae al wildcard de workspace ⇒ 404.
      assert_raise DranWeb.NotFoundError, fn -> live(conn, ~p"/settings/agents") end

      # No queda NADA del CRUD de actores en la UI.
      refute html =~ ~s(id="create-actor-form")
      refute html =~ ~s(phx-click="create_actor")
      refute html =~ ~s(phx-click="edit_actor")
      refute html =~ ~s(phx-click="delete_actor")
      refute has_element?(view, "#agents-tab")
    end

    test "crear una API key NO crea ninguna fila en actors (P7)", %{conn: conn} do
      unique = System.unique_integer([:positive])

      {:ok, ws} =
        Knowledge.create_workspace(%{name: "NoActor #{unique}", slug: "no-actor-#{unique}"})

      user = Accounts.get_user_by_email("test_user")
      before_count = Dran.Repo.aggregate(Dran.Actors.Actor, :count)

      {:ok, key} =
        Accounts.create_api_key(%{
          name: "no-actor-key-#{unique}",
          workspace_ids: [{ws.id, "read"}],
          created_by_user_id: user.id
        })

      after_count = Dran.Repo.aggregate(Dran.Actors.Actor, :count)

      assert after_count == before_count
      # La key existe, no tiene actor y sí tiene dueño (created_by_user_id).
      assert is_nil(key.actor_id)
      assert key.created_by_user_id == user.id
      assert Dran.Actors.get_actor_by_name(key.name) == nil
    end

    test "crear una key desde la UI no crea actores y revela el token una vez (P7/P6)", %{
      conn: conn
    } do
      unique = System.unique_integer([:positive])

      {:ok, ws} =
        Knowledge.create_workspace(%{name: "UIKey #{unique}", slug: "ui-key-#{unique}"})

      before_count = Dran.Repo.aggregate(Dran.Actors.Actor, :count)

      {:ok, view, _html} = live(conn, ~p"/settings/api-keys")

      html = view |> element("#new-api-key-btn") |> render_click()
      assert html =~ ~s(id="create-key-form")

      html =
        view
        |> element("#create-key-form")
        |> render_submit(%{
          "key" => %{
            "name" => "ui-agent-#{unique}",
            "workspaces" => %{ws.id => %{"enabled" => "true", "level" => "read"}}
          }
        })

      assert html =~ ~s(id="revealed-api-key-card")
      assert html =~ ~s(id="copy-revealed-key-btn")
      assert Dran.Repo.aggregate(Dran.Actors.Actor, :count) == before_count
      # La identidad de la key es su nombre, visible en la tabla.
      assert html =~ "ui-agent-#{unique}"
    end

    test "la matriz de workspaces de una key se edita en su fila (P6)", %{conn: conn} do
      unique = System.unique_integer([:positive])

      {:ok, ws_a} =
        Knowledge.create_workspace(%{name: "KeyA #{unique}", slug: "key-a-#{unique}"})

      {:ok, ws_b} =
        Knowledge.create_workspace(%{name: "KeyB #{unique}", slug: "key-b-#{unique}"})

      user = Accounts.get_user_by_email("test_user")

      {:ok, key} =
        Accounts.create_api_key(%{
          name: "mutable-#{unique}",
          workspace_ids: [{ws_a.id, "read"}],
          created_by_user_id: user.id
        })

      {:ok, view, _html} = live(conn, ~p"/settings/api-keys")

      html = view |> element("#api-key-#{key.id} button[phx-click='edit_api_key']") |> render_click()
      assert html =~ ~s(id="edit-key-form")

      html =
        view
        |> element("#edit-key-form")
        |> render_submit(%{
          "key" => %{
            "workspaces" => %{
              ws_a.id => %{"enabled" => "true", "level" => "write"},
              ws_b.id => %{"enabled" => "true", "level" => "read"}
            }
          }
        })

      assert html =~ t("API key access updated")

      # El token se preserva y los niveles quedaron persistidos.
      reloaded = Dran.Repo.preload(Dran.Repo.get!(Dran.Accounts.ApiKey, key.id), :api_key_workspaces)
      levels = Map.new(reloaded.api_key_workspaces, &{&1.workspace_id, &1.access_level})
      assert levels[ws_a.id] == "write"
      assert levels[ws_b.id] == "read"
      assert Accounts.valid_api_key?(key.token) != :error
    end

    test "revocar una key la marca revoked y ofrece restaurarla", %{conn: conn} do
      unique = System.unique_integer([:positive])

      {:ok, ws} = Knowledge.create_workspace(%{name: "Rev #{unique}", slug: "rev-#{unique}"})
      user = Accounts.get_user_by_email("test_user")

      {:ok, key} =
        Accounts.create_api_key(%{
          name: "revocable-#{unique}",
          workspace_ids: [{ws.id, "read"}],
          created_by_user_id: user.id
        })

      {:ok, view, _html} = live(conn, ~p"/settings/api-keys")

      html =
        view
        |> element("#api-key-#{key.id} button[phx-click='revoke_api_key']")
        |> render_click()

      assert Accounts.valid_api_key?(key.token) == :error
      assert html =~ t("Revoked")
      assert has_element?(view, "#api-key-#{key.id} button[phx-click='restore_api_key']")
    end

    test "copy_api_key_prefix de la key de OTRO usuario se rechaza sin filtrar el prefijo", %{
      conn: _conn
    } do
      unique = System.unique_integer([:positive])

      {:ok, ws} =
        Knowledge.create_workspace(%{name: "ForeignW3 #{unique}", slug: "foreign-w3-#{unique}"})

      {:ok, non_owner} =
        Accounts.create_user(%{email: "plain-w3-#{unique}@example.com", name: "Plain"})

      {:ok, _} = Accounts.add_user_to_workspace(non_owner, ws)

      {:ok, other_user} =
        Accounts.create_user(%{email: "other-w3-#{unique}@example.com", name: "Other"})

      {:ok, _} = Accounts.add_user_to_workspace(other_user, ws)

      {:ok, foreign_key} =
        Accounts.create_api_key(%{
          name: "Foreign W3 key",
          workspace_ids: [{ws.id, "read"}],
          created_by_user_id: other_user.id
        })

      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session(:user, "plain-w3-#{unique}@example.com")
        |> Plug.Conn.put_session(:workspace_slug, "personal")

      {:ok, view, _html} = live(conn, ~p"/settings/api-keys")

      html = render_click(view, "copy_api_key_prefix", %{"id" => foreign_key.id})

      assert html =~ t("No autorizado.")
    end
  end

  # ── P8: atribución server-side desde la key (sin actor) ────────────────────

  describe "atribución de una key nueva (P8)" do
    test "owner_user_id = created_by_user_id de la key", %{conn: _conn} do
      unique = System.unique_integer([:positive])

      {:ok, owner} =
        Accounts.create_user(%{email: "p8-owner-#{unique}@example.com", name: "P8 Owner"})

      {:ok, ws} =
        Knowledge.create_workspace(%{name: "P8 #{unique}", slug: "p8-#{unique}"})

      {:ok, _} = Accounts.add_user_to_workspace(owner, ws)

      {:ok, key} =
        Accounts.create_api_key(%{
          name: "p8-agent-#{unique}",
          workspace_ids: [{ws.id, "write"}],
          created_by_user_id: owner.id
        })

      # El mapa sintético que el router inyecta al autenticar la key.
      identity = %{
        key_name: key.name,
        agent_name: Dran.Auth.agent_name_from_headers([]),
        created_by_user_id: key.created_by_user_id,
        owner_user_id: key.created_by_user_id
      }

      assert Dran.Auth.resolve_owner_user_id(identity) == owner.id
      # Sin header ⇒ created_by es el name de la key.
      assert Dran.Auth.resolve_created_by(identity) == key.name
      assert Dran.Auth.resolve_owner(identity) == key.name

      # Con header ⇒ created_by es el header, no el name de la key (M7).
      with_header = %{identity | agent_name: Dran.Auth.agent_name_from_headers([{"x-hermes-agent", "coder"}])}
      assert Dran.Auth.resolve_created_by(with_header) == "coder"
      # El dueño NO cambia por el header.
      assert Dran.Auth.resolve_owner_user_id(with_header) == owner.id
    end
  end

  # Tests L104, L128 → /admin/users
  describe "google open signup toggle" do
    setup do
      Application.put_env(:dran, :google_oauth,
        client_id: "test-client",
        client_secret: "test-secret",
        redirect_uri: "http://localhost/auth/google/callback"
      )

      on_exit(fn ->
        Application.delete_env(:dran, :google_oauth)
        Dran.Repo.delete_all(from s in "settings", where: s.key == "wiki_google_open_signup")
      end)

      :ok
    end

    test "toggling persists the setting and re-renders the checkbox", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/users")

      toggle = "input[phx-click='toggle_wiki_google_signup']"

      refute Dran.Settings.get("wiki_google_open_signup")
      refute has_element?(view, "#{toggle}[checked]")

      _ = view |> element(toggle) |> render_click()

      assert Dran.Settings.get("wiki_google_open_signup") == true
      assert has_element?(view, "#{toggle}[checked]")

      _ = view |> element(toggle) |> render_click()

      refute Dran.Settings.get("wiki_google_open_signup")
      refute has_element?(view, "#{toggle}[checked]")
    end
  end

  # Test L199 → /admin (tabs change)
  test "admin page is organized as a landing with links to all sections", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/admin")

    # Navigation links to every admin section
    for tab_path <- ~w(/admin/users /admin/workspaces /admin/models /admin/system /admin/jobs) do
      assert html =~ tab_path
    end

    # Landing shows the admin title and intro
    assert html =~ t("Admin")

    # Automation settings are NOT on the landing (lives in /:ws/settings)
    refute html =~ "worker_max_pages"
  end

  # Tests L148, L176, L215 → /:ws/settings (reescribir a per-ws)
  describe "automation (brain tuning) per-workspace" do
    setup do
      # Create a workspace for automation settings tests
      unique = System.unique_integer([:positive])

      {:ok, ws} =
        Knowledge.create_workspace(%{
          name: "Brain Tuning #{unique}",
          slug: "brain-tuning-#{unique}",
          # The settings form only renders when all required features are on
          enabled_features: %{feature_clusters: true}
        })

      # Add the test user to the workspace as owner
      user = Accounts.get_user_by_email("test_user")
      Accounts.add_user_to_workspace(user, ws)

      {:ok, ws: ws}
    end

    test "renders the automation form with default values", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/settings")

      # Navigate to the Automation tab
      html =
        view
        |> element("button[phx-click='select_tab'][phx-value-tab='brain_tuning']")
        |> render_click()

      # Section heading (localized)
      assert html =~ t("Automation")

      # Primary fields visible
      for name <- ~w(worker_max_pages) do
        assert html =~ name
      end

      # Advanced thresholds tucked behind the details toggle
      assert html =~ "Avanzado"

      for name <- ~w(semantic_threshold_short semantic_threshold_mid semantic_threshold_long) do
        assert html =~ name
      end

      # Removed knobs are gone from the form
      refute html =~ "worker_max_sources"

      # Default values come from Workspace.get_tuning/2
      assert html =~ to_string(Dran.Workspace.get_tuning(ws, :semantic_threshold_short))
      assert html =~ to_string(Dran.Workspace.get_tuning(ws, :worker_max_pages))

      # Summary language select renders with the auto default
      assert has_element?(
               view,
               "#workspace-settings-form select[name='workspace[summary_language]']"
             )

      assert html =~ t("Summary language")

      assert html =~ t("Save")
    end

    test "saving the form persists values and shows a flash", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/settings")

      # Navigate to the Automation tab
      _ =
        view
        |> element("button[phx-click='select_tab'][phx-value-tab='brain_tuning']")
        |> render_click()

      html =
        view
        |> form("#workspace-settings-form", %{
          "workspace" => %{
            "semantic_threshold_short" => "0.10",
            "semantic_threshold_mid" => "0.25",
            "semantic_threshold_long" => "0.30",
            "worker_max_pages" => "42",
            "summary_language" => "en"
          }
        })
        |> render_submit()

      # Success flash (localized)
      assert html =~ t("Settings saved")

      # The new values are persisted and readable via Workspace.get_tuning/2
      reloaded = Knowledge.get_workspace!(ws.id)
      assert Dran.Workspace.get_tuning(reloaded, :worker_max_pages) == 42
      assert Dran.Workspace.get_tuning(reloaded, :semantic_threshold_short) == 0.10

      # The language pin is persisted as-is
      assert reloaded.summary_language == "en"
    end

    test "the brain tuning form still renders the worker_max_pages input", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/settings")

      # Navigate to the Automation tab
      html =
        view
        |> element("button[phx-click='select_tab'][phx-value-tab='brain_tuning']")
        |> render_click()

      assert html =~ "worker_max_pages"
      assert html =~ t("Max pages per run")
    end
  end


  describe "custom page types per workspace (W2)" do
    setup do
      unique = System.unique_integer([:positive])

      {:ok, ws} =
        Knowledge.create_workspace(%{name: "Types #{unique}", slug: "types-#{unique}"})

      user = Accounts.get_user_by_email("test_user")
      Accounts.add_user_to_workspace(user, ws)

      {:ok, ws: ws}
    end

    test "the page types tab lists the 4 built-in types plus the custom ones", %{conn: conn, ws: ws} do
      {:ok, ws} =
        Knowledge.update_workspace_settings(ws, %{
          workspace_page_types: [
            %{
              "slug" => "recipe",
              "label" => "Receta",
              "plural" => "Recetas",
              "path" => "recipes",
              "icon" => "hero-beaker",
              "color" => "amber",
              "meta_fields" => []
            }
          ]
        })

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/settings")

      html =
        view
        |> element("button[phx-click='select_tab'][phx-value-tab='page_types']")
        |> render_click()

      # Custom type is listed, marked as custom, with its declared path
      assert html =~ "Receta"
      assert html =~ "recipes"
      assert html =~ t("custom")

      # The built-ins are still there and are not removable
      assert html =~ "Note"
      assert has_element?(view, "#page-type-note")
      assert has_element?(view, "#page-type-recipe")
    end

    test "adding a custom type from the form persists it", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/settings")

      _ =
        view
        |> element("button[phx-click='select_tab'][phx-value-tab='page_types']")
        |> render_click()

      html =
        view
        |> form("form[phx-submit='add_custom_page_type']", %{
          "workspace" => %{
            "slug" => "recipe",
            "label" => "Receta",
            "plural" => "Recetas",
            "path" => "recipes",
            "icon" => "hero-beaker",
            "color" => "amber",
            "meta_fields" => ""
          }
        })
        |> render_submit()

      assert html =~ t("Page type added")

      reloaded = Knowledge.get_workspace!(ws.id)
      assert Dran.Workspace.custom_page_type_slugs(reloaded) == ["recipe"]
      assert Knowledge.page_types(reloaded) == ~w(note entity concept reference recipe)
    end

    test "a duplicate slug is rejected with a visible message", %{conn: conn, ws: ws} do
      {:ok, ws} =
        Knowledge.update_workspace_settings(ws, %{
          workspace_page_types: [
            %{
              "slug" => "recipe",
              "label" => "Receta",
              "plural" => "Recetas",
              "path" => "recipes",
              "icon" => "hero-beaker",
              "color" => "amber",
              "meta_fields" => []
            }
          ]
        })

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/settings")

      _ =
        view
        |> element("button[phx-click='select_tab'][phx-value-tab='page_types']")
        |> render_click()

      html =
        view
        |> form("form[phx-submit='add_custom_page_type']", %{
          "workspace" => %{
            "slug" => "recipe",
            "label" => "Otra",
            "plural" => "Otras",
            "path" => "other-recipes",
            "icon" => "",
            "color" => "",
            "meta_fields" => ""
          }
        })
        |> render_submit()

      assert html =~ "duplicate slug"

      # Nothing was persisted
      reloaded = Knowledge.get_workspace!(ws.id)
      assert Dran.Workspace.custom_page_type_slugs(reloaded) == ["recipe"]
    end

    test "removing a custom type drops it from the effective list", %{conn: conn, ws: ws} do
      {:ok, ws} =
        Knowledge.update_workspace_settings(ws, %{
          workspace_page_types: [
            %{
              "slug" => "recipe",
              "label" => "Receta",
              "plural" => "Recetas",
              "path" => "recipes",
              "icon" => "hero-beaker",
              "color" => "amber",
              "meta_fields" => []
            }
          ]
        })

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/settings")

      _ =
        view
        |> element("button[phx-click='select_tab'][phx-value-tab='page_types']")
        |> render_click()

      html =
        view
        |> element("button[phx-click='remove_custom_page_type'][phx-value-slug='recipe']")
        |> render_click()

      assert html =~ t("Page type removed")

      reloaded = Knowledge.get_workspace!(ws.id)
      assert Dran.Workspace.custom_page_types(reloaded) == []
    end
  end

  # Tests L222, L229, L236 → /admin/system
  test "the Sistema header exists with monitoring and instance sections", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/admin/system")

    assert html =~ t("Sistema")
    assert html =~ t("Monitoreo, configuración de instancia y entorno.")
    assert html =~ t("Instancia")
    assert html =~ t("Base de datos")
    assert html =~ t("Uptime")
  end

  test "inference test button is present in the Inference API section", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/admin/system")

    assert html =~ ~s(phx-click="test_inference")
    assert html =~ t("Probar conexión")
  end

  test "clicking the test button shows the testing state", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/system")

    html = render_click(view, "test_inference")
    # The button immediately switches to "Probando..." state
    assert html =~ t("Probando...")
    # The button is disabled while testing
    assert html =~ "disabled"
  end

  # Instance settings (Settings-backed) + monitoring on /admin/system
  describe "admin system: instancia y monitoreo" do
    test "renders the instance form and monitoring widgets", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/admin/system")

      assert has_element?(view, "#instance-form")
      assert has_element?(view, "#instance_default_workspace_slug")
      assert has_element?(view, "#instance_api_token")
      assert has_element?(view, "button[phx-click='generate_token']")
      assert has_element?(view, "button[phx-click='refresh_monitoring']")
    end

    test "refresh_monitoring populates the widgets", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/system")

      html = render_click(view, "refresh_monitoring")
      # table count appears after a real collect_monitoring run
      assert html =~ "tablas"
      assert html =~ t("% usado")
    end

    test "save_instance persists settings and creates the default workspace", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/system")

      html =
        render_submit(view, "save_instance", %{
          "instance" => %{
            "default_workspace_slug" => "instancia-test",
            "default_workspace_name" => "Instancia Test",
            "api_token" => ""
          }
        })

      assert html =~ t("Configuración de instancia guardada.")
      assert Dran.Settings.get("default_workspace_slug") == "instancia-test"
      assert Dran.Settings.get("default_workspace_name") == "Instancia Test"
      assert Dran.Auth.default_workspace_slug() == "instancia-test"
      assert Dran.Auth.default_workspace_name() == "Instancia Test"
      assert Dran.Auth.default_context_configured?()
      # The workspace is created on save (mirrors release setup behaviour)
      assert Dran.Knowledge.get_workspace_by_slug("instancia-test")
    end

    test "save_instance rejects an invalid slug", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/system")

      html =
        render_submit(view, "save_instance", %{
          "instance" => %{
            "default_workspace_slug" => "Invalid Slug!!",
            "default_workspace_name" => "",
            "api_token" => ""
          }
        })

      assert html =~ t("Slug inválido: usa minúsculas, dígitos y guiones.")
      assert is_nil(Dran.Settings.get("default_workspace_slug"))
    end

    test "generate_token stores a random token in settings", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/system")

      html = render_click(view, "generate_token")

      assert html =~ t("Token generado y copiado al portapapeles.")
      token = Dran.Settings.get("api_token")
      assert is_binary(token) and byte_size(token) >= 20
      assert Dran.Auth.valid_token?(token)
    end

    test "clearing the token field disables the legacy admin token", %{conn: conn} do
      # Put the token BEFORE mount so the form carries it, then clear it.
      Dran.Settings.put("api_token", "old-token")
      {:ok, view, _html} = live(conn, ~p"/admin/system")

      render_submit(view, "save_instance", %{
        "instance" => %{
          "default_workspace_slug" => "",
          "default_workspace_name" => "",
          "api_token" => ""
        }
      })

      assert is_nil(Dran.Settings.get("api_token"))
      refute Dran.Auth.valid_token?("old-token")
      refute Dran.Auth.valid_token?("dran-token")
    end
  end

  # Test L246 → /admin/models
  test "models tab renders the selects with a per-model test button", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/admin/models")

    assert html =~ ~s(id="models-form")

    for purpose <- ~w(model_chat model_embedding) do
      assert html =~ ~s(id="models_#{purpose}")
      assert html =~ ~s(id="test_model_#{purpose}")
      assert html =~ "data-model-key=\"#{purpose}\""
    end

    assert html =~ t("Probar")
  end

  # Tests L283, L301, L314, L334, L342 → /admin/jobs
  describe "jobs panel (brain tab)" do
    import Ecto.Query

    alias Dran.Jobs

    setup do
      # The panel reads the global "disabled_jobs" setting and the run reports
      # of the shared default context — start from a clean slate and leave none
      # behind (mirrors Dran.JobsTest's defensive cleanup).
      context =
        Dran.Knowledge.get_workspace_by_slug("personal") ||
          elem(Dran.Knowledge.create_workspace(%{name: "Personal", slug: "personal"}), 1)

      clear_disabled_jobs!()

      on_exit(fn ->
        # The OnExitHandler process owns no sandbox connection — check one out
        # or the delete_all below dies with an OwnershipError and fails the test.
        Ecto.Adapters.SQL.Sandbox.checkout(Dran.Repo)

        clear_disabled_jobs!()
        delete_job_reports!(context.id)
      end)

      :ok
    end

    test "renders the 6 registered jobs with toggles and run buttons", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin/jobs")

      assert html =~ t("Jobs programados")
      assert length(Jobs.list()) == 7

      for job <- Jobs.list() do
        assert html =~ ~s(id="job-row-#{job.key}")
        assert html =~ job.label
        assert html =~ ~s(id="job-toggle-#{job.key}")
        assert html =~ ~s(id="job-run-#{job.key}")
      end

      # No runs yet — gray "Nunca" badge and an enabled "Correr ahora" per job
      assert html =~ t("Nunca")
      assert html =~ t("Correr ahora")
    end

    test "toggle_job persists the enabled state and re-renders it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/jobs")
      assert Jobs.enabled?(:curator_daily)

      _ = view |> element("#job-toggle-curator_daily") |> render_click()
      refute Jobs.enabled?(:curator_daily)
      refute has_element?(view, "#job-toggle-curator_daily[checked]")

      _ = view |> element("#job-toggle-curator_daily") |> render_click()
      assert Jobs.enabled?(:curator_daily)
      assert has_element?(view, "#job-toggle-curator_daily[checked]")
    end

    test "run_job marks only that job as running, then flashes on completion", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/jobs")

      html = view |> element("#job-run-pagerank_nightly") |> render_click()

      # The Task's {:job_run_done, ...} message is handled after this reply, so
      # the returned HTML deterministically shows the running state — and only
      # for the clicked job.
      assert html =~ t("Corriendo…")
      assert html =~ ~r/<button(?=[^>]*\bdisabled\b)(?=[^>]*id="job-run-pagerank_nightly")/
      refute html =~ ~r/<button(?=[^>]*\bdisabled\b)(?=[^>]*id="job-run-curator_daily")/

      # Completion clears the running state, flashes and refreshes the list.
      # (The Task → run report wiring for the real job is covered in Dran.JobsTest.)
      send(view.pid, {:job_run_done, :pagerank_nightly, {:ok, %{}}})
      html = render(view)
      assert html =~ "Job completado: PageRank"
      refute html =~ t("Corriendo…")
    end

    test "job_run_done with an error result flashes the failure", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/jobs")

      send(view.pid, {:job_run_done, :curator_daily, {:error, :boom}})

      assert render(view) =~ "Job falló: Curator"
    end

    test "shows the last run with badge, relative time, duration and report link", %{conn: conn} do
      # Cheap real job (the same one Dran.JobsTest runs) — writes a run report.
      {:ok, report} = Jobs.run_now(:pagerank_nightly)

      {:ok, _view, html} = live(conn, ~p"/admin/jobs")

      # Green ok badge, relative time linking to the report, compact duration
      assert html =~ "badge-success"
      assert html =~ ~s(href="/reports/#{report.slug}")
      assert html =~ t("just now")
      assert html =~ ~r/\d+(\.\d+)? (ms|s)/
    end

    defp clear_disabled_jobs! do
      Dran.Repo.delete_all(from s in "settings", where: s.key == "disabled_jobs")
    end

    defp delete_job_reports!(workspace_id) do
      keys = Enum.map(Jobs.list_keys(), &Atom.to_string/1)

      Dran.Repo.delete_all(
        from p in Dran.Knowledge.Page,
          where: p.workspace_id == ^workspace_id and p.page_type == "report",
          where: fragment("?->>'job_key'", p.meta) in ^keys
      )
    end
  end
end
