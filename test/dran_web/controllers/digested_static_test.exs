defmodule DranWeb.DigestedStaticTest do
  @moduledoc """
  Digested top-level static assets must be served by `Plug.Static`.

  In production the endpoint loads `cache_static_manifest`, so `~p"/logo.png"`
  (the in-app header logo in `Layouts`/`DashboardLive`) resolves to the
  digested path `/logo-<md5>.png?vsn=d`. `Plug.Static`'s `:only` list matches
  the first path segment *exactly*, so the digested name (`logo-<hash>.png`) is
  rejected unless the endpoint also sets `:only_matching`. When rejected, the
  request falls through to the router, which redirects to `/login` (302) and
  the logo silently renders broken.

  This test materialises the digested copy of `logo.png` on disk (exactly what
  `mix phx.digest` does at build time) and asserts the endpoint serves it, so
  dropping `:only_matching` from the endpoint's `Plug.Static` config fails here.
  """
  use DranWeb.ConnCase, async: false

  setup do
    src = Application.app_dir(:dran, "priv/static/logo.png")
    digest = :crypto.hash(:md5, File.read!(src)) |> Base.encode16(case: :lower)
    dst = Application.app_dir(:dran, "priv/static/logo-#{digest}.png")

    File.cp!(src, dst)
    on_exit(fn -> File.rm(dst) end)

    {:ok, digest: digest}
  end

  test "serves the digested logo.png referenced by ~p in production", %{
    conn: conn,
    digest: digest
  } do
    conn = get(conn, "/logo-#{digest}.png")

    assert conn.status == 200
    assert [content_type | _] = get_resp_header(conn, "content-type")
    assert content_type =~ "image/png"
    # PNG magic bytes.
    assert <<0x89, "PNG\r\n", 0x1A, "\n", _rest::binary>> = conn.resp_body
  end
end
