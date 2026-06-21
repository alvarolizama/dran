defmodule DranWeb.PageControllerTest do
  use DranWeb.ConnCase

  test "GET / redirects to login when unauthenticated", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn, 302) == "/login"
  end
end
