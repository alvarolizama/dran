defmodule DranWeb.HealthController do
  @moduledoc """
  Liveness probe for the container and the proxy.

  It answers `200` as soon as the endpoint is listening and **touches nothing
  else**: no session, no cookie, no database. That is deliberate — the probe
  runs while the app is warming up (the boot creates the database, migrates,
  seeds the default workspace and backfills personal workspaces), which is
  exactly when the connection pool is busiest, so a probe that queries the
  database can time a healthy container out.

  A readiness check that *should* look at the database belongs on another route
  (`/ready`), and that is the one the proxy watches — never this one. Family
  standard: `SPEC-docker.md` §The `/health` endpoint.

  Point the healthcheck at `/health`, NEVER at `/`: `/` redirects to `/login`
  (302) and a proxy configured to expect 200 reads it as "down" and returns 502
  over a container that is serving fine.
  """

  use DranWeb, :controller

  @body ~s({"status":"ok"})

  @doc "GET /health — always 200 while the endpoint is up."
  def show(conn, _params) do
    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(200, @body)
  end
end
