defmodule DranWeb.HealthControllerTest do
  @moduledoc """
  The liveness-probe contract: 200, no session, **no database**.

  This test deliberately does not use `DranWeb.ConnCase`. That helper takes a
  sandbox owner, which hands the test a working connection and would hide a
  `/health` that queries the database (the old version ran `SELECT 1` and
  answered 503 when the pool was not up yet — see the controller's moduledoc and
  the family standard, `SPEC-docker.md` §The `/health` endpoint).

  Running without an owner, any query dies with `DBConnection.OwnershipError`,
  so a green 200 here is structural proof that the probe touches nothing.

  The path is a plain string on purpose: `~p` comes from
  `Phoenix.VerifiedRoutes`, which ConnCase sets up, and using ConnCase is
  exactly what this test must not do.
  """

  use ExUnit.Case, async: true

  import Plug.Conn
  import Phoenix.ConnTest

  @endpoint DranWeb.Endpoint

  test "GET /health answers 200 without a session and without a database" do
    conn = get(build_conn(), "/health")

    assert conn.status == 200
    assert response(conn, 200) == ~s({"status":"ok"})
    assert get_resp_header(conn, "cache-control") == ["no-store"]

    refute get_resp_header(conn, "set-cookie")
           |> Enum.any?(&String.contains?(&1, "session"))
  end
end
