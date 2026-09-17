defmodule DranWeb.LiveAuth do
  @moduledoc """
  `on_mount` hooks for privileged LiveView route groups.

  Router pipeline plugs run on the HTTP request only. When a LiveView mounts (or
  re-mounts) over the websocket, the plug does NOT run again — the mount is
  driven by the session carried in the signed cookie. A privileged LiveView
  guarded only by a pipeline plug is therefore protected on the initial dead
  render and nowhere else, which is why every privileged `live` route group
  needs an `on_mount` twin in the same `live_session`.

  Each hook mirrors its pipeline plug's predicate EXACTLY, so the HTTP path and
  the socket path can never drift apart.

  | Hook | Mirrors (router) |
  |---|---|
  | `:require_admin` | `pipeline :admin` → `require_instance_owner/2` |
  """

  import Phoenix.LiveView, only: [push_navigate: 2]

  @doc """
  Mirror of the `:admin` pipeline (`require_instance_owner/2`).

  Instance-owner-only: a session without a `user` goes to `/login`; a session
  whose cached `is_owner` is explicitly `false` goes to the dashboard. Anything
  else continues (matching the plug, which deliberately lets a session with no
  `is_owner` flag through for pre-multi-user sessions).
  """
  def on_mount(:require_admin, _params, session, socket) do
    case session do
      %{"user" => user} when is_binary(user) ->
        if session["is_owner"] == false do
          {:halt, push_navigate(socket, to: "/")}
        else
          {:cont, socket}
        end

      _ ->
        {:halt, push_navigate(socket, to: "/login")}
    end
  end
end
