defmodule DranWeb.DashboardAuthFlowTest do
  use DranWeb.ConnCase, async: false

  alias Dran.Accounts

  setup %{conn: conn} do
    {:ok, user} =
      Accounts.create_user_with_password(%{
        email: "flow@example.com",
        password: "supersecret123"
      })

    {:ok, conn: conn, user: user}
  end

  test "login redirects to / (dashboard)", %{conn: conn, user: user} do
    # Fetch the CSRF token from the login page first
    conn = get(conn, ~p"/login")
    csrf = conn.private.plug_session["_csrf_token"]

    conn =
      post(conn, ~p"/session", %{
        "_csrf_token" => csrf,
        "login" => %{"username" => user.email, "password" => "supersecret123"}
      })

    assert redirected_to(conn, 302) == "/"
  end

  test "login with wrong password stays on /login", %{conn: conn, user: user} do
    conn = get(conn, ~p"/login")
    csrf = conn.private.plug_session["_csrf_token"]

    conn =
      post(conn, ~p"/session", %{
        "_csrf_token" => csrf,
        "login" => %{"username" => user.email, "password" => "wrong-password"}
      })

    assert redirected_to(conn, 302) == "/login"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Invalid"
  end

  test "dashboard header shows kanban link and logged-in user api token", %{
    conn: conn,
    user: user
  } do
    conn =
      conn
      |> Plug.Test.init_test_session(%{user: user.email, context_slug: "personal"})

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ ~p"/kanban"
    assert html =~ "dashboard-api-token"
    # Full token is only available for copying, never rendered visible
    assert html =~ "data-token=\"#{user.api_token}\""
    assert html =~ "••••••"
    refute html =~ Regex.compile!(">#{Regex.escape(user.api_token)}<")
    assert html =~ "CopyApiToken"
  end
end
