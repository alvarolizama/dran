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

  | Hook | Mirrors (router) | Predicate |
  |---|---|---|
  | `:require_admin` | `pipeline :admin` → `require_instance_owner/2` | instance OWNER: no `user` → `/login`; an explicit `is_owner: false` → the dashboard; a session with no `is_owner` flag continues (the plug deliberately lets pre-multi-user sessions through) |
  | `:require_instance_admin` | `pipeline :instance_admin` → `require_instance_admin/2` | instance owner ∪ `instance_role` admin/owner — what `/settings/instance` configures (page types, features, tuning, the services policy). A normal user does NOT read it: not an instance admin → `/`; no `user` → `/login`. The `instance_role` comes from the ROW (`User.instance_admin?/1`), so a session without the `is_owner` flag is not trusted |
  """

  import Phoenix.LiveView, only: [push_navigate: 2]

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

  # El doc del predicado vive en el moduledoc: dos `@doc` sobre la misma
  # función se pisan (warning de compilación con `--warnings-as-errors`).
  def on_mount(:require_instance_admin, _params, session, socket) do
    case session do
      %{"user" => user} when is_binary(user) ->
        if instance_admin?(user) do
          {:cont, socket}
        else
          {:halt, push_navigate(socket, to: "/")}
        end

      _ ->
        {:halt, push_navigate(socket, to: "/login")}
    end
  end

  # La fila decide, no la bandera cacheada: un usuario BORRADO con
  # `is_owner: true` viejo no entra, y el `instance_role` no viaja en la sesión.
  # Mismo predicado que el plug (`Router.instance_admin_session?/1`).
  defp instance_admin?(user) do
    case Dran.Accounts.get_user_by_email(user) do
      nil -> false
      db_user -> Dran.Accounts.User.instance_admin?(db_user)
    end
  end
end
