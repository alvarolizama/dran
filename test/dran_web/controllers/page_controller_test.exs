defmodule DranWeb.PageControllerTest do
  use DranWeb.ConnCase, async: false

  alias Dran.Accounts

  setup %{conn: conn} do
    # A user must exist so the auth plug redirects to /login instead of /setup
    {:ok, _user} =
      Accounts.create_user_with_password(%{
        email: "page-test@example.com",
        password: "supersecret123"
      })

    {:ok, conn: conn}
  end

  test "GET / redirects to login when unauthenticated", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn, 302) == "/login"
  end
end
