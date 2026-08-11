defmodule DranWeb.DashboardAuthFlowTest do
  use DranWeb.ConnCase, async: false

  alias Dran.Accounts

  setup %{conn: conn} do
    {:ok, user} =
      Accounts.create_user_with_password(%{
        email: "flow@example.com",
        password: "supersecret123"
      })

    # Make the user admin so they can see the dashboard
    {:ok, user} = Accounts.update_user(user, %{is_admin: true})

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

    {:ok, _view, html} = live(conn, ~p"/panel")

    assert html =~ ~p"/panel/kanban"
    assert html =~ "dashboard-api-token"
    # SEC-005: only the prefix is rendered — the full token never reaches the DOM
    assert html =~ String.slice(user.api_token, 0, 8)
    assert html =~ "••••••"
    refute html =~ Regex.compile!(">#{Regex.escape(user.api_token)}<")
    assert html =~ "copy_api_token"
  end
end
