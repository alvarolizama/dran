defmodule DranWeb.SettingsLiveTest do
  use DranWeb.ConnCase, async: false

  import Ecto.Query

  alias Dran.Accounts
  alias Dran.Knowledge

  # Gettext wrapper. English is the app default locale, so the msgid is
  # what the app renders unless a test pins another locale.
  defp t(msgid), do: Gettext.gettext(DranWeb.Gettext, msgid)

  # HEEx escapes text nodes (apostrophes become &#39;), so any assertion on a
  # sentence copied from the UI has to compare against the escaped form.
  defp esc(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

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

      html =
        view |> element("#api-key-#{key.id} button[phx-click='edit_api_key']") |> render_click()

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
      reloaded =
        Dran.Repo.preload(Dran.Repo.get!(Dran.Accounts.ApiKey, key.id), :api_key_workspaces)

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

      assert html =~ t("Not authorized.")
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
      with_header = %{
        identity
        | agent_name: Dran.Auth.agent_name_from_headers([{"x-hermes-agent", "coder"}])
      }

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
        Dran.Settings.delete("wiki_google_open_signup")
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
      assert html =~ "Advanced"

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

  # ── clarity of the workspace configuration screen ─────────────────────────

  describe "workspace settings tabs are self-explanatory" do
    setup do
      unique = System.unique_integer([:positive])

      {:ok, ws} =
        Knowledge.create_workspace(%{name: "Clarity #{unique}", slug: "clarity-#{unique}"})

      user = Accounts.get_user_by_email("test_user")
      Accounts.add_user_to_workspace(user, ws)

      {:ok, ws: ws}
    end

    test "the General tab shows the slug, explains visibility and the default flag", %{
      conn: conn,
      ws: ws
    } do
      {:ok, view, html} = live(conn, ~p"/#{ws.slug}/settings")

      assert has_element?(view, "#general-section")
      # The workspace slug is the URL identity: visible, and clearly read-only.
      assert html =~ ws.slug
      assert html =~ t("read-only")
      assert has_element?(view, "#workspace-visibility")
      assert has_element?(view, "#workspace-is-default")

      # The visibility help describes the CURRENT value, not both options.
      assert html =~
               t(
                 "Public: every user of this instance can open and read this workspace; only members can edit it."
               )

      refute html =~
               esc(
                 t(
                   "Private: only members see this workspace. It is absent from other users' workspace lists."
                 )
               )
    end

    test "switching to private explains the new value on save", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/settings")

      html =
        view
        |> form("#workspace-general-form", %{
          "workspace" => %{"name" => ws.name, "visibility" => "private", "is_default" => "false"}
        })
        |> render_submit()

      assert html =~ t("Workspace saved")
      assert Knowledge.get_workspace!(ws.id).visibility == "private"

      assert html =~
               esc(
                 t(
                   "Private: only members see this workspace. It is absent from other users' workspace lists."
                 )
               )
    end

    test "the Features tab groups the toggles and explains each one", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/settings")

      html =
        view
        |> element("button[phx-click='select_tab'][phx-value-tab='features']")
        |> render_click()

      assert has_element?(view, "#features-section")
      assert html =~ t("Knowledge base")
      assert html =~ t("Insights")

      # Every toggle has a stable id and a caption saying what it gives you.
      for feature <- ~w(search graph journey collections clusters reports activity) do
        assert has_element?(view, "#feature-#{feature}")
        assert html =~ esc(t(feature_description(feature)))
      end

      # And its current state is spelled out, with the same word used by the
      # Page types list.
      assert html =~ t("Enabled")
    end

    test "turning a feature off is persisted and shown as disabled", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/settings")

      _ =
        view
        |> element("button[phx-click='select_tab'][phx-value-tab='features']")
        |> render_click()

      # LiveViewTest refuses an arbitrary value for a checkbox (`value="true"` is
      # the only one it accepts), so the event is submitted directly — exactly
      # what a browser sends: only the checked boxes appear, unchecked ones are
      # absent from the params.
      html =
        render_submit(view, "save", %{
          "workspace" => %{},
          "enabled_features" => %{"graph" => "true"}
        })

      assert html =~ t("Settings saved")

      reloaded = Knowledge.get_workspace!(ws.id)
      refute Dran.Workspace.feature_enabled?(reloaded, "search")
      assert Dran.Workspace.feature_enabled?(reloaded, "graph")
      # Nothing is deleted by a toggle — that is what the caption promises.
      assert Knowledge.page_types(reloaded) == ~w(note entity concept reference)
    end

    test "the Users tab explains what each role can do", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/settings")

      html =
        view
        |> element("button[phx-click='select_tab'][phx-value-tab='users']")
        |> render_click()

      assert has_element?(view, "#users-section")

      # One legend line per role, so the select's four options are not just words.
      for role <- ~w(owner admin editor viewer) do
        assert html =~ t(role_description(role))
      end

      # The member row carries a role select with an id and a confirmed removal.
      assert has_element?(view, "#member-role-#{Accounts.get_user_by_email("test_user").id}")
      assert has_element?(view, "#user-search-form")
      assert html =~ t("Remove from workspace")
    end
  end

  # Mirrors the private helpers in the LiveView, so the test asserts the copy
  # that actually ships rather than a second copy written by hand.
  defp feature_description("search"),
    do: "Full-text and semantic search across this workspace's pages."

  defp feature_description("graph"), do: "The relationship map of this workspace's pages."

  defp feature_description("journey"),
    do: "Timeline of how this workspace's knowledge grew over time."

  defp feature_description("collections"),
    do: "Curated and smart page lists that update as the workspace changes."

  defp feature_description("clusters"),
    do: "Related pages grouped into themes by the nightly job."

  defp feature_description("reports"),
    do: "Generated reports written from this workspace's content."

  defp feature_description("activity"), do: "Log of the recent changes to this workspace's pages."

  defp role_description("owner"), do: "Owner: settings, members and content."
  defp role_description("admin"), do: "Admin: settings and members, plus content."
  defp role_description("editor"), do: "Editor: create and edit pages, no access to settings."
  defp role_description("viewer"), do: "Viewer: read pages only."

  describe "custom page types per workspace (W2)" do
    setup do
      unique = System.unique_integer([:positive])

      {:ok, ws} =
        Knowledge.create_workspace(%{name: "Types #{unique}", slug: "types-#{unique}"})

      user = Accounts.get_user_by_email("test_user")
      Accounts.add_user_to_workspace(user, ws)

      {:ok, ws: ws}
    end

    test "the page types tab lists the 4 built-in types plus the custom ones", %{
      conn: conn,
      ws: ws
    } do
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

  # ── the meta_fields JSON editor ────────────────────────────────────────────

  describe "custom page type meta fields editor" do
    setup do
      unique = System.unique_integer([:positive])

      {:ok, ws} =
        Knowledge.create_workspace(%{name: "Editor #{unique}", slug: "editor-#{unique}"})

      user = Accounts.get_user_by_email("test_user")
      Accounts.add_user_to_workspace(user, ws)

      {:ok, ws: ws}
    end

    test "valid JSON is reported live as parsed fields", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/settings")
      open_page_types_tab(view)

      html =
        view
        |> form("#custom-page-type-form", %{
          "workspace" => type_params(meta_fields: ~s([["text", "cuisine", "Cuisine"]]))
        })
        |> render_change()

      assert html =~ "1 valid field"
      assert html =~ "text · cuisine"
      refute html =~ t("Invalid JSON")
    end

    test "malformed JSON is reported live and never persisted", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/settings")
      open_page_types_tab(view)

      params = %{"workspace" => type_params(meta_fields: ~s([["text", ]]))}

      html = view |> form("#custom-page-type-form", params) |> render_change()
      assert html =~ t("Invalid JSON")

      # Submitting refuses too, and the workspace is untouched.
      html = view |> form("#custom-page-type-form", params) |> render_submit()
      assert html =~ t("Invalid JSON")
      assert Dran.Workspace.custom_page_type_slugs(Knowledge.get_workspace!(ws.id)) == []
    end

    test "a JSON object (not an array) is rejected", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/settings")
      open_page_types_tab(view)

      html =
        view
        |> form("#custom-page-type-form", %{
          "workspace" => type_params(meta_fields: ~s({"text": "x"}))
        })
        |> render_change()

      assert html =~ t("Meta fields must be a JSON array of fields.")
    end

    test "an unknown field type is rejected naming the type and the allowed ones", %{
      conn: conn,
      ws: ws
    } do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/settings")
      open_page_types_tab(view)

      html =
        view
        |> form("#custom-page-type-form", %{
          "workspace" => type_params(meta_fields: ~s([["number", "cook_time", "Cook time"]]))
        })
        |> render_change()

      assert html =~ "unknown type"
      assert html =~ "text, date, props"
    end

    test "a field missing its label is rejected", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/settings")
      open_page_types_tab(view)

      html =
        view
        |> form("#custom-page-type-form", %{
          "workspace" => type_params(meta_fields: ~s([["text", "cuisine"]]))
        })
        |> render_change()

      assert html =~ "Field 1: the label must be a non-empty string."
    end

    test "loading an example fills the editor with a valid template", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/settings")
      open_page_types_tab(view)

      # The example is relative to what is already in the form, so seed a value
      # first to prove the button replaces bytes rather than appending.
      view
      |> form("#custom-page-type-form", %{"workspace" => type_params(meta_fields: "garbage")})
      |> render_change()

      html = render_click(view, "load_meta_fields_example", %{"example" => "date_url"})

      assert html =~ "date · published_at"
      assert html =~ "text · source_url"

      # And it is submittable as-is.
      html =
        render_submit(view, "add_custom_page_type", %{
          "workspace" =>
            type_params(meta_fields: Jason.encode!([["date", "published_at", "Published at"]]))
        })

      assert html =~ t("Page type added")

      reloaded = Knowledge.get_workspace!(ws.id)
      [entry] = Dran.Workspace.custom_page_types(reloaded)
      assert entry["meta_fields"] == [["date", "published_at", "Published at"]]
    end

    test "clearing the editor is not an error", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/settings")
      open_page_types_tab(view)

      html = render_click(view, "clear_meta_fields")

      assert html =~ t("Empty is fine — the type simply gets no extra fields.")
    end

    test "the built-in fields and the live preview are present", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/settings")
      open_page_types_tab(view)

      assert has_element?(view, "#custom-page-type-form")
      assert has_element?(view, "#workspace_slug")
      assert has_element?(view, "#workspace_path")
      assert has_element?(view, "#workspace_meta_fields")
      assert has_element?(view, "#page-types-section")
      assert has_element?(view, "#custom-page-type-form button[type=submit]")
    end
  end

  defp open_page_types_tab(view) do
    view
    |> element("button[phx-click='select_tab'][phx-value-tab='page_types']")
    |> render_click()
  end

  # A valid custom page type payload, with `meta_fields` overridable.
  defp type_params(opts) do
    Map.merge(
      %{
        "slug" => "recipe",
        "label" => "Recipe",
        "plural" => "Recipes",
        "path" => "recipes",
        "icon" => "hero-beaker",
        "color" => "#F59E0B",
        "meta_fields" => ""
      },
      Map.new(opts, fn {k, v} -> {to_string(k), v} end)
    )
  end

  # Tests L222, L229, L236 → /admin/system
  test "the Sistema header exists with monitoring and instance sections", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/admin/system")

    assert html =~ t("Sistema")
    assert html =~ t("Monitoring, instance configuration and environment.")
    assert html =~ t("Instance")
    assert html =~ t("Database")
    assert html =~ t("Uptime")
  end

  test "inference test button is present in the Inference API section", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/admin/system")

    assert html =~ ~s(phx-click="test_inference")
    assert html =~ t("Test connection")
  end

  test "clicking the test button shows the testing state", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/system")

    html = render_click(view, "test_inference")
    # The button immediately switches to the "Testing..." state
    assert html =~ t("Testing...")
    # The button is disabled while testing
    assert html =~ "disabled"
  end

  # Instance settings (Settings-backed) + monitoring on /admin/system
  describe "admin system: instancia y monitoreo" do
    test "renders the instance form and monitoring widgets", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/system")

      assert has_element?(view, "#instance-form")
      assert has_element?(view, "#instance_api_token")
      assert has_element?(view, "button[phx-click='generate_token']")
      assert has_element?(view, "button[phx-click='refresh_monitoring']")
    end

    test "carries no default-workspace control — that lives in /admin/workspaces", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/admin/system")

      # No panel, no read-only display and no form field: the instance default
      # is the workspace flagged as default, set from /admin/workspaces.
      refute has_element?(view, "#instance-default-workspace")
      refute has_element?(view, "#instance-default-workspace-source")
      refute has_element?(view, "#instance_default_workspace_slug")
      refute has_element?(view, "#instance_default_workspace_name")
      refute html =~ t("Default workspace")
      refute html =~ t("Used when a user has no workspace of their own and no active session.")
    end

    test "refresh_monitoring populates the widgets", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/system")

      html = render_click(view, "refresh_monitoring")
      # Table count and disk usage appear after a real collect_monitoring run.
      assert html =~ t("tables")
      assert html =~ "used ·"
    end

    test "save_instance persists the admin token only", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/system")

      html =
        render_submit(view, "save_instance", %{
          "instance" => %{"api_token" => "instancia-test-token"}
        })

      assert html =~ t("Instance configuration saved.")
      assert Dran.Settings.get("api_token") == "instancia-test-token"
      # The default workspace is not configured from this form — nor from any
      # settings key: the legacy override is gone.
      assert is_nil(Dran.Settings.get("default_workspace_slug"))
      refute Dran.Settings.get("default_workspace_name")
    end

    test "generate_token stores a random token in settings", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/system")

      html = render_click(view, "generate_token")

      assert html =~ t("Token generated and copied to the clipboard.")
      token = Dran.Settings.get("api_token")
      assert is_binary(token) and byte_size(token) >= 20
      assert Dran.Auth.valid_token?(token)
    end

    test "clearing the token field disables the legacy admin token", %{conn: conn} do
      # Put the token BEFORE mount so the form carries it, then clear it.
      Dran.Settings.put("api_token", "old-token")
      {:ok, view, _html} = live(conn, ~p"/admin/system")

      render_submit(view, "save_instance", %{
        "instance" => %{"api_token" => ""}
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

    assert html =~ t("Test")
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
      assert html =~ t("Never")
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

      assert render(view) =~ "Job failed: Curator"
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
      Dran.Settings.delete("disabled_jobs")
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
