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
    # W6: /admin/workspaces se retiró — el landing enlaza las cinco secciones
    # que quedan.
    for tab_path <- ~w(/admin/users /admin/groups /admin/models /admin/system /admin/jobs) do
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
      # Single-workspace model: the page edits the instance workspace.
      {:ok, ws: Dran.DataCase.ensure_workspace!()}
    end

    test "renders the automation form with default values", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, ~p"/admin/instance")

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
      {:ok, view, _html} = live(conn, ~p"/admin/instance")

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
      {:ok, view, _html} = live(conn, ~p"/admin/instance")

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

      ws = Dran.DataCase.ensure_workspace!()
      {:ok, ws: ws}
    end

    test "the General tab shows the slug and the private access note", %{
      conn: conn,
      ws: ws
    } do
      {:ok, view, html} = live(conn, ~p"/admin/instance")

      assert has_element?(view, "#general-section")
      # The workspace slug is the URL identity: visible, and clearly read-only.
      assert html =~ ws.slug
      assert html =~ t("read-only")

      # W6: no default flag — with one container there is nothing to pick.
      refute has_element?(view, "#workspace-is-default")

      # No visibility control any more: the section states the invariant (every
      # workspace is private, access is granted from the Users tab) instead of
      # offering a public/private choice that no longer exists.
      refute has_element?(view, "#workspace-visibility")
      refute html =~ t("Public")

      assert html =~
               esc(
                 t(
                   "Only the people you add from the Users tab can open this workspace, and it never appears in anyone else's list. There is no public, discoverable tier."
                 )
               )
    end

    test "saving the General tab keeps the workspace private", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, ~p"/admin/instance")

      html =
        view
        |> form("#workspace-general-form", %{"workspace" => %{"name" => ws.name}})
        |> render_submit()

      assert html =~ t("Workspace saved")
      assert Knowledge.get_workspace!(ws.id).visibility == "private"
    end

    test "the Features tab groups the toggles and explains each one", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, ~p"/admin/instance")

      html =
        view
        |> element("button[phx-click='select_tab'][phx-value-tab='features']")
        |> render_click()

      assert has_element?(view, "#features-section")
      assert html =~ t("Knowledge base")
      assert html =~ t("Insights")
      assert html =~ t("Surfaces")

      # Every toggle has a stable id and a caption saying what it gives you.
      for feature <-
            ~w(search graph journey collections clusters reports activity memory board goals plans services) do
        assert has_element?(view, "#feature-#{feature}")
        assert html =~ esc(t(feature_description(feature)))
      end

      # And its current state is spelled out, with the same word used by the
      # Page types list.
      assert html =~ t("Enabled")
    end

    test "turning a feature off is persisted and shown as disabled", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, ~p"/admin/instance")

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

    # "the Users tab explains what each role can do" — removed in W1: the
    # Users tab (workspace membership) died with the multi-workspace model;
    # roles are the instance role now (W2 rewires the tab as Users & groups).
    test "the Users tab explains what each role can do", %{conn: conn, ws: ws} do
      assert is_map(conn) and is_map(ws)
    end

    test "las cinco superficies se apagan desde Features y su entrada sale del nav", %{
      conn: conn,
      ws: ws
    } do
      {:ok, view, _html} = live(conn, ~p"/admin/instance")

      view
      |> element("button[phx-click='select_tab'][phx-value-tab='features']")
      |> render_click()

      # Solo Memory queda encendida: las otras cuatro superficies se apagan.
      render_submit(view, "save", %{
        "workspace" => %{},
        "enabled_features" => %{"memory" => "true"}
      })

      reloaded = Knowledge.get_workspace!(ws.id)
      assert Dran.Workspace.feature_enabled?(reloaded, "memory")

      for key <- ~w(board goals plans services) do
        refute Dran.Workspace.feature_enabled?(reloaded, key)
      end

      # La entrada sale del nav de una página de conocimiento: apagar quita el
      # punto de entrada, nunca el dato ni la ruta.
      {:ok, nav_view, _html} = live(conn, ~p"/notes")

      assert has_element?(nav_view, "aside a[href='/memory']")

      for path <- ~w(/tasks /goals /plans /services) do
        refute has_element?(nav_view, "aside a[href='#{path}']")
      end
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

  defp feature_description("memory"),
    do: "The atomic facts your workers keep — what the brain remembers between runs."

  defp feature_description("board"), do: "The column view of your tasks, grouped by status."
  defp feature_description("goals"), do: "Objectives with their progress and their subgoals."
  defp feature_description("plans"), do: "Plans with their checklist and their steps."

  defp feature_description("services"),
    do: "The apps you connect so your agent can act on them."

  defp role_description("owner"), do: "Owner: settings, members and content."
  defp role_description("admin"), do: "Admin: settings and members, plus content."
  defp role_description("editor"), do: "Editor: create and edit pages, no access to settings."
  defp role_description("viewer"), do: "Viewer: read pages only."

  describe "custom page types per workspace (W2)" do
    setup do
      # Single-workspace model: the page edits the instance workspace.
      {:ok, ws: Dran.DataCase.ensure_workspace!()}
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

      {:ok, view, _html} = live(conn, ~p"/admin/instance")

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
      {:ok, view, _html} = live(conn, ~p"/admin/instance")

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

      {:ok, view, _html} = live(conn, ~p"/admin/instance")

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

      {:ok, view, _html} = live(conn, ~p"/admin/instance")

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
      # Single-workspace model: the page edits the instance workspace.
      {:ok, ws: Dran.DataCase.ensure_workspace!()}
    end

    test "valid JSON is reported live as parsed fields", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, ~p"/admin/instance")
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
      {:ok, view, _html} = live(conn, ~p"/admin/instance")
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
      {:ok, view, _html} = live(conn, ~p"/admin/instance")
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
      {:ok, view, _html} = live(conn, ~p"/admin/instance")
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
      {:ok, view, _html} = live(conn, ~p"/admin/instance")
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
      {:ok, view, _html} = live(conn, ~p"/admin/instance")
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
      {:ok, view, _html} = live(conn, ~p"/admin/instance")
      open_page_types_tab(view)

      html = render_click(view, "clear_meta_fields")

      assert html =~ t("Empty is fine — the type simply gets no extra fields.")
    end

    test "the built-in fields and the live preview are present", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, ~p"/admin/instance")
      open_page_types_tab(view)

      assert has_element?(view, "#custom-page-type-form")
      assert has_element?(view, "#workspace_slug")
      assert has_element?(view, "#workspace_path")
      assert has_element?(view, "#workspace_meta_fields")
      assert has_element?(view, "#page-types-section")
      assert has_element?(view, "#custom-page-type-form button[type=submit]")
    end
  end

  describe "el alta de tipos se edita con controles" do
    setup do
      {:ok, ws: Dran.DataCase.ensure_workspace!()}
    end

    test "el icono es un datalist y los defaults escriben el mismo campo", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, ~p"/admin/instance")
      open_page_types_tab(view)

      # C8.2 de la casa: texto libre CON sugerencias, sobre el mismo campo.
      assert has_element?(view, "#workspace_icon[list='workspace_icon-list']")
      assert has_element?(view, "#workspace_icon-list option[value='hero-beaker']")

      # Los defaults son nombres REALES: el plugin de heroicons genera una clase
      # por icono del dep, así que uno inventado se dibujaría vacío.
      names =
        render(view)
        |> then(&Regex.scan(~r/id="icon-choice-(hero-[a-z0-9-]+)"/, &1))
        |> Enum.map(&Enum.at(&1, 1))

      assert length(names) >= 12

      for name <- names do
        file =
          "deps/heroicons/optimized/24/outline/" <>
            String.replace_prefix(name, "hero-", "") <> ".svg"

        assert File.exists?(file), "el default #{name} no existe en el dep"
      end

      # Lleno lo mínimo y elijo un default: escribe el MISMO campo del form…
      render_change(view, "validate_custom_page_type", %{
        "workspace" => type_params(meta_fields: ""),
        "_target" => ["workspace[label]"]
      })

      render_click(view, "pick_icon", %{"icon" => "hero-trophy"})
      assert has_element?(view, "#workspace_icon[value='hero-trophy']")

      # …y el submit guarda ESE icono (un solo valor, sin normalización nueva).
      view |> form("#custom-page-type-form") |> render_submit()

      reloaded = Knowledge.get_workspace!(ws.id)
      assert Dran.Workspace.page_type_ui(reloaded, "recipe").icon == "hero-trophy"

      # Un valor fuera de los defaults no entra por el evento (fail-closed).
      render_click(view, "pick_icon", %{"icon" => "hero-inventado"})
      refute has_element?(view, "#workspace_icon[value='hero-inventado']")
    end

    test "un tipo armado con filas persiste su lista JSON", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, ~p"/admin/instance")
      open_page_types_tab(view)

      # Agrego la primera fila: nace vacía y visible (tipo por defecto).
      render_click(view, "add_meta_field_row")

      assert has_element?(view, "#meta-field-row-0")
      assert has_element?(view, "#meta-field-key-0")
      assert has_element?(view, "#meta-field-label-0")
      assert has_element?(view, "#meta-field-type-0")

      # La lleno: el JSON del form se re-deriva de la FILA.
      render_change(view, "validate_custom_page_type", %{
        "workspace" => type_params(meta_fields: ~s([["text", "", ""]])),
        "meta_field_rows" => %{
          "0" => %{"type" => "text", "key" => "cuisine", "label" => "Cuisine"}
        },
        "_target" => ["meta_field_rows[0][key]"]
      })

      # El fallback avanzado muestra exactamente lo mismo: un solo valor.
      assert has_element?(view, "#workspace_meta_fields")
      assert has_element?(view, "#meta-field-key-0[value='cuisine']")

      # Y el submit guarda ESA lista: el formato de cable no cambia.
      render_submit(view, "add_custom_page_type", %{
        "workspace" => type_params(meta_fields: ~s([["text", "", ""]])),
        "meta_field_rows" => %{
          "0" => %{"type" => "text", "key" => "cuisine", "label" => "Cuisine"}
        }
      })

      reloaded = Knowledge.get_workspace!(ws.id)

      assert Dran.Workspace.page_type_meta_fields(reloaded, "recipe") == [
               {"text", "cuisine", "Cuisine"}
             ]
    end

    test "quitar una fila y los payloads forjados no rompen el editor", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/instance")
      open_page_types_tab(view)

      render_change(view, "validate_custom_page_type", %{
        "workspace" => type_params(meta_fields: ~s([["text", "a", "A"], ["date", "b", "B"]])),
        "_target" => ["workspace[meta_fields]"]
      })

      assert has_element?(view, "#meta-field-row-0")
      assert has_element?(view, "#meta-field-row-1")

      # Quitar la primera deja la segunda con su tipo y su key.
      render_click(view, "remove_meta_field_row", %{"index" => "0"})

      refute has_element?(view, "#meta-field-row-1")
      assert has_element?(view, "#meta-field-key-0[value='b']")
      assert has_element?(view, "#meta-field-type-0 option[value='date'][selected]")

      # Un índice forjado no revienta ni cambia la lista (fail-closed).
      render_click(view, "remove_meta_field_row", %{"index" => "no-existe"})

      assert has_element?(view, "#meta-field-key-0[value='b']")
    end

    test "una fila sin key se reporta, y un JSON roto conserva el texto", %{
      conn: conn,
      ws: ws
    } do
      {:ok, view, _html} = live(conn, ~p"/admin/instance")
      open_page_types_tab(view)

      # Una fila a medio llenar: el validador dice qué falta…
      render_change(view, "validate_custom_page_type", %{
        "workspace" => type_params(meta_fields: ~s([["text", "", ""]])),
        "_target" => ["workspace[meta_fields]"]
      })

      assert render(view) =~ "Field 1: the key must be a non-empty string."

      # …y el submit la rechaza sin guardar nada.
      render_submit(view, "add_custom_page_type", %{
        "workspace" => type_params(meta_fields: ~s([["text", "", ""]]))
      })

      assert render(view) =~ "Field 1: the key must be a non-empty string."
      assert Dran.Workspace.custom_page_type_slugs(Knowledge.get_workspace!(ws.id)) == []

      # Un JSON que no decodifica NO se pisa: las filas se apagan y el texto
      # queda ahí para arreglarlo.
      html =
        render_change(view, "validate_custom_page_type", %{
          "workspace" => type_params(meta_fields: "[["),
          "_target" => ["workspace[meta_fields]"]
        })

      refute has_element?(view, "#meta-field-rows")
      assert html =~ t("Fix the JSON below to keep editing these fields as rows.")
      assert has_element?(view, "#workspace_meta_fields")

      # Y agregar una fila con el JSON roto tampoco lo destruye.
      render_click(view, "add_meta_field_row")

      refute has_element?(view, "#meta-field-rows")
      assert render(view) =~ t("Invalid JSON")
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
  test "the System header exists with monitoring and instance sections", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/admin/system")

    # t("System") — NOT a Spanish literal: the msgid is English and the page
    # follows the locale. (It used to be gettext("Sistema"), i.e. Spanish
    # hard-coded as the source string, which is why the assertion had to say
    # "Sistema" and the English UI showed Spanish.)
    assert html =~ t("System")
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
