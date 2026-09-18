defmodule DranWeb.AccountSettingsLiveTest do
  use DranWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Dran.Accounts

  defp t(msgid), do: Gettext.gettext(DranWeb.Gettext, msgid)

  defp create_user(attrs \\ %{}) do
    {:ok, user} =
      Accounts.create_user_with_password(%{
        email: "account@test.dev",
        password: "password123",
        name: "Test User"
      })

    {user, Map.merge(%{email: "account@test.dev", password: "password123"}, attrs)}
  end

  defp owner_conn(conn) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:user, "account@test.dev")
    |> Plug.Conn.put_session(:is_owner, true)
  end

  describe "settings tabs" do
    test "renders tab bar with Account and API keys", %{conn: conn} do
      {_user, _attrs} = create_user()

      {:ok, _view, html} = live(owner_conn(conn), ~p"/settings/account")

      assert html =~ t("Account")
      assert html =~ t("API keys")
      assert html =~ t("Profile")
      assert html =~ t("Password")
      assert html =~ t("Google Account")
      assert html =~ "Test User"
    end

    test "api keys tab renders the key management", %{conn: conn} do
      {_user, _attrs} = create_user()

      {:ok, _view, html} = live(owner_conn(conn), ~p"/settings/api-keys")

      assert html =~ t("API keys")
      assert html =~ ~s(id="api-keys-tab")
    end

    test "updates the display name", %{conn: conn} do
      {_user, _attrs} = create_user()

      {:ok, view, _html} = live(owner_conn(conn), ~p"/settings/account")

      view
      |> form("#profile-form", %{"profile" => %{"name" => "Nuevo Nombre"}})
      |> render_submit()

      assert render(view) =~ "Nuevo Nombre"
      assert Accounts.get_user_by_email("account@test.dev").name == "Nuevo Nombre"
    end

    test "changes password with correct current password", %{conn: conn} do
      {_user, _attrs} = create_user()

      {:ok, view, _html} = live(owner_conn(conn), ~p"/settings/account")

      view
      |> form("#password-form", %{
        "password" => %{"current_password" => "password123", "password" => "newpassword456"}
      })
      |> render_submit()

      assert render(view) =~ t("Password changed")

      assert {:error, :unauthorized} =
               Accounts.authenticate_user("account@test.dev", "password123")

      assert {:ok, _user} = Accounts.authenticate_user("account@test.dev", "newpassword456")
    end

    test "rejects wrong current password", %{conn: conn} do
      {_user, _attrs} = create_user()

      {:ok, view, _html} = live(owner_conn(conn), ~p"/settings/account")

      view
      |> form("#password-form", %{
        "password" => %{"current_password" => "wrong", "password" => "newpassword456"}
      })
      |> render_submit()

      assert render(view) =~ "The current password is incorrect"
      assert {:ok, _user} = Accounts.authenticate_user("account@test.dev", "password123")
    end

    test "unlinks google account", %{conn: conn} do
      {user, _attrs} = create_user()

      {:ok, user} = Accounts.link_google(user, %{google_id: "google-123", avatar_url: "http://x"})
      assert user.google_id == "google-123"

      {:ok, view, _html} = live(owner_conn(conn), ~p"/settings/account")

      view
      |> element("button[phx-click='unlink_google']")
      |> render_click()

      assert render(view) =~ t("Google account unlinked")
      assert Accounts.get_user_by_email("account@test.dev").google_id == nil
    end
  end

  # ── language preference ────────────────────────────────────────────────────

  # Decodes the payload of a signed flash carried by a live navigation
  # ("HS256.<payload>.<signature>").
  defp flash_payload(signed) do
    signed
    |> String.split(".")
    |> Enum.at(1)
    |> Base.url_decode64!(padding: false)
  end

  describe "language preference" do
    test "a new account defaults to English", %{conn: conn} do
      {user, _attrs} = create_user()
      assert user.locale == "en"

      {:ok, view, html} = live(owner_conn(conn), ~p"/settings/account")

      assert html =~ t("Language")
      assert has_element?(view, "#locale-form")
      # Both shipped languages are offered, and English is the selected one.
      assert html =~ "English"
      assert html =~ "Español"
      assert has_element?(view, "#locale_locale option[value='en'][selected]")
    end

    test "switching to Spanish persists it and re-renders in Spanish", %{conn: conn} do
      {_user, _attrs} = create_user()

      {:ok, view, _html} = live(owner_conn(conn), ~p"/settings/account")

      # Switching the language remounts the tab: the whole page (layout and
      # components included) has to come out in the new language, and an
      # in-place diff does not carry all of it.
      redirected =
        view
        |> form("#locale-form", %{"locale" => %{"locale" => "es"}})
        |> render_change()

      assert {:error, {:live_redirect, opts}} = redirected
      assert opts.to == "/settings/account"
      # The flash travels with the navigation in the language that was just
      # picked, not the old one. LiveView ships it signed (Plug.Crypto), so the
      # payload is decoded rather than compared as a map.
      assert flash_payload(opts.flash) =~ "Idioma actualizado"

      assert Accounts.get_user_by_email("account@test.dev").locale == "es"

      # The remount renders the whole page in Spanish — the same path the
      # browser takes after following the navigate.
      {:ok, view, html} = live(owner_conn(conn), ~p"/settings/account")
      assert html =~ "Cuenta"
      assert html =~ "Perfil"
      assert html =~ "Idioma"
      assert has_element?(view, "#locale_locale option[value='es'][selected]")
    end

    test "an unsupported locale is rejected at the domain layer", %{conn: conn} do
      # The selector only renders the shipped locales, so a client cannot even
      # submit "fr" (LiveViewTest refuses it too). The guarantee has to hold
      # below the UI as well: nothing unsupported ever reaches users.locale.
      {user, _attrs} = create_user()

      {:ok, updated} = Accounts.update_locale(user, "fr")
      assert updated.locale == "en"

      {:ok, view, _html} = live(owner_conn(conn), ~p"/settings/account")
      assert has_element?(view, "#locale_locale option[value='en'][selected]")
    end

    test "an account saved as Spanish loads the Spanish UI on a fresh mount", %{conn: conn} do
      {user, _attrs} = create_user()
      {:ok, _user} = Accounts.update_locale(user, "es")

      {:ok, _view, html} = live(owner_conn(conn), ~p"/settings/account")

      assert html =~ "Cuenta"
      refute html =~ ">Account<"
    end

    test "the document language follows the resolved locale", %{conn: conn} do
      # The `<html lang>` attribute drives screen readers, hyphenation and the
      # browser's own spell-checking — it has to match what is on the page.
      {user, _attrs} = create_user()

      {:ok, _view, html} = live(owner_conn(conn), ~p"/settings/account")
      assert html =~ ~s(lang="en")

      {:ok, _user} = Accounts.update_locale(user, "es")

      {:ok, _view, html} = live(owner_conn(conn), ~p"/settings/account")
      assert html =~ ~s(lang="es")
    end

    test "the locale is normalized from region variants" do
      {user, _attrs} = create_user()
      {:ok, updated} = Accounts.update_locale(user, "es-AR")

      assert updated.locale == "es"
    end
  end
end
