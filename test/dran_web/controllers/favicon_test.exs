defmodule DranWeb.FaviconTest do
  @moduledoc """
  The Dran icon must be served as a PNG.

  SVG icons were not rendering reliably (GitHub README and some browsers), so
  the brand icon ships as `priv/static/logo.png`, referenced both as the
  favicon and in the README header. `favicon.ico` stays as a legacy fallback.

  The PNG must be listed in `DranWeb.static_paths/0`; otherwise `Plug.Static`
  never serves it, a request to `/logo.png` falls through to the router and
  redirects to `/login`, and the browser silently shows no icon. These tests
  pin the static allow-list so the icon keeps loading.
  """
  use DranWeb.ConnCase, async: true

  test "serves the PNG logo/favicon at /logo.png", %{conn: conn} do
    conn = get(conn, "/logo.png")

    assert conn.status == 200
    assert [content_type | _] = get_resp_header(conn, "content-type")
    assert content_type =~ "image/png"
    # PNG magic bytes.
    assert <<0x89, "PNG\r\n", 0x1A, "\n", _rest::binary>> = conn.resp_body
  end

  test "serves the legacy favicon.ico fallback", %{conn: conn} do
    conn = get(conn, "/favicon.ico")
    assert conn.status == 200
  end
end
