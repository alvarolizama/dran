defmodule DranWeb.FaviconTest do
  @moduledoc """
  The Dran icon must be served as the favicon.

  `favicon.svg` was missing from `DranWeb.static_paths/0`, so `Plug.Static`
  never served it: a request to `/favicon.svg` fell through to the router and
  redirected to `/login`, and the browser silently fell back to `favicon.ico`.
  These tests pin the static allow-list so the crisp SVG icon keeps loading.
  """
  use DranWeb.ConnCase, async: true

  test "serves the SVG favicon at /favicon.svg", %{conn: conn} do
    conn = get(conn, "/favicon.svg")

    assert conn.status == 200
    assert [content_type | _] = get_resp_header(conn, "content-type")
    assert content_type =~ "image/svg+xml"
    assert conn.resp_body =~ "<svg"
  end

  test "serves favicon.ico", %{conn: conn} do
    conn = get(conn, "/favicon.ico")
    assert conn.status == 200
  end
end
