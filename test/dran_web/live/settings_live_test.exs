defmodule DranWeb.SettingsLiveTest do
  use DranWeb.ConnCase, async: false

  alias Dran.Accounts
  alias Dran.Settings

  # Gettext wrapper — the app default locale is "es", so assertions must
  # match the translated strings, not the English msgids.
  defp t(msgid), do: Gettext.gettext(DranWeb.Gettext, msgid)

  setup %{conn: conn} do
    # Create (or fetch) an admin user whose email matches the session value the
    # router's require_admin plug looks up. The /settings route is admin-only.
    case Accounts.get_user_by_email("test_user") do
      nil ->
        {:ok, _user} =
          Accounts.create_user(%{email: "test_user", name: "Test Admin", is_admin: true})

      _ ->
        :ok
    end

    # Log in — init_test_session is needed because ConnCase doesn't pipe
    # through the browser pipeline that Auth expects.
    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user, "test_user")
      |> Plug.Conn.put_session(:context_slug, "personal")

    {:ok, conn: conn}
  end

  test "renders the brain tuning form with default values", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/settings/brain")

    # Section heading (localized)
    assert html =~ t("Brain tuning")

    # Primary fields visible
    for name <- ~w(agent_max_pages daily_note_enabled) do
      assert html =~ name
    end

    # Advanced thresholds tucked behind the details toggle
    assert html =~ "Avanzado"

    for name <- ~w(semantic_threshold_short semantic_threshold_mid semantic_threshold_long) do
      assert html =~ name
    end

    # Removed knobs are gone from the form
    refute html =~ "agent_max_sources"

    # Default values come from Dran.Settings.defaults/0
    defaults = Settings.defaults()
    assert html =~ to_string(defaults["semantic_threshold_short"])
    assert html =~ to_string(defaults["agent_max_pages"])
    assert html =~ t("Save")
  end

  test "saving the form persists values and shows a flash", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings/brain")

    html =
      view
      |> form("#brain-tuning-form", %{
        "settings" => %{
          "semantic_threshold_short" => "0.10",
          "semantic_threshold_mid" => "0.25",
          "semantic_threshold_long" => "0.30",
          "agent_max_pages" => "42",
          "daily_note_enabled" => "true"
        }
      })
      |> render_submit()

    # Success flash (localized)
    assert html =~ t("Settings saved")

    # The new values are persisted and readable via Settings.get/1
    assert Settings.get("agent_max_pages") == 42
    assert Settings.get("semantic_threshold_short") == 0.10
    assert Settings.get("daily_note_enabled") == true
  end

  test "settings page is organized by tabs with users as default", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/settings")

    # Tab navigation present with all tabs
    for tab_path <-
          ~w(/settings/users /settings/contexts /settings/brain /settings/models /settings/system /settings/danger) do
      assert html =~ tab_path
    end

    # Default tab is users — shows user management
    assert html =~ t("Add User")

    # Brain tuning is NOT on the default tab (lives in /settings/brain)
    refute html =~ "agent_max_pages"
  end

  test "the brain tuning form still renders the agent_max_pages input", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/settings/brain")

    assert html =~ "agent_max_pages"
    assert html =~ t("Max pages per run")
  end

  test "the Entorno header exists with its read-only caption", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/settings/system")

    assert html =~ t("Entorno")
    assert html =~ t("Read-only — loaded from environment variables at startup.")
  end

  test "inference test button is present in the Inference API section", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/settings/system")

    assert html =~ "phx-click=\"test_inference\""
    assert html =~ t("Probar conexión")
  end

  test "clicking the test button shows the testing state", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings/system")

    html = render_click(view, "test_inference")
    # The button immediately switches to "Probando..." state
    assert html =~ t("Probando...")
    # The button is disabled while testing
    assert html =~ "disabled"
  end
end
