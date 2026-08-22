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
    test "renders tab bar with Account and API Keys", %{conn: conn} do
      {_user, _attrs} = create_user()

      {:ok, _view, html} = live(owner_conn(conn), ~p"/settings/account")

      assert html =~ t("Account")
      assert html =~ t("API Keys")
      assert html =~ t("Profile")
      assert html =~ t("Password")
      assert html =~ t("Google Account")
      assert html =~ "Test User"
    end

    test "api_keys tab renders keys content", %{conn: conn} do
      {_user, _attrs} = create_user()

      {:ok, _view, html} = live(owner_conn(conn), ~p"/settings/api_keys")

      assert html =~ t("API Keys")
      assert html =~ t("Add Key")
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

      assert render(view) =~ "La contraseña actual es incorrecta"
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
end
