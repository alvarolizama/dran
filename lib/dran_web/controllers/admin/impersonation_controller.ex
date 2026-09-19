defmodule DranWeb.ImpersonationController do
  @moduledoc """
  Controller for user impersonation (instance owner/admin only).

  - `POST /admin/impersonate/:id` — impersonate a user
  - `DELETE /admin/impersonate` — stop impersonating

  The routes themselves are defined by the parent in the router (`:admin`
  pipeline, which enforces `is_owner`). This controller adds defense-in-depth
  checks on top.
  """
  use DranWeb, :controller

  alias DranWeb.Plugs.Auth

  @impersonator_key "impersonator"
  @impersonator_workspace_key "impersonator_workspace"

  def create(conn, %{"id" => target_id}) do
    admin_email = Auth.current_user(conn)

    cond do
      # Defense-in-depth: the :admin pipeline already guarantees the caller is
      # the instance owner; re-check fail-closed in case the route is ever
      # mounted outside that pipeline.
      not is_binary(admin_email) or get_session(conn, "is_owner") != true ->
        conn
        |> put_flash(:error, "Instance owner access required")
        |> redirect(to: ~p"/")

      # Block re-impersonation while an impersonation is already active.
      is_binary(get_session(conn, @impersonator_key)) ->
        conn
        |> put_flash(:error, "Already impersonating a user. Exit first.")
        |> redirect(to: ~p"/admin")

      true ->
        load_and_impersonate(conn, target_id)
    end
  end

  defp load_and_impersonate(conn, target_id) do
    case Dran.Accounts.get_user(target_id) do
      nil ->
        conn
        |> put_flash(:error, "User not found")
        |> redirect(to: ~p"/admin/users")

      %{is_owner: true} ->
        # Block impersonating another owner/admin.
        conn
        |> put_flash(:error, "Cannot impersonate another owner.")
        |> redirect(to: ~p"/admin/users")

      target_user ->
        admin_email = Auth.current_user(conn)
        admin_workspace_slug = get_session(conn, "workspace_slug")

        # The target's session is established via Auth.login (recomputes
        # is_owner fail-closed) and reset to the workspace that user actually
        # lands in — their default when reachable, else the instance default
        # when reachable, else the only workspace they can access.
        target_slug = Dran.Accounts.session_workspace_slug(target_user)

        conn =
          conn
          # Login first — it recomputes is_owner fail-closed and switches to
          # the target's session/workspace. login clears :impersonator, so the
          # impersonator context must be set AFTER login.
          |> Auth.login(target_user.email, target_slug)
          |> put_session(@impersonator_key, admin_email)
          |> put_session(@impersonator_workspace_key, admin_workspace_slug)

        Dran.Log.create(%{
          action: "impersonate.start",
          subject: "#{admin_email} -> #{target_user.email}",
          details: %{workspace_slug: target_slug}
        })

        conn
        |> put_flash(:info, "Impersonating #{target_user.email}")
        |> redirect(to: ~p"/")
    end
  end

  def delete(conn, _params) do
    case get_session(conn, @impersonator_key) do
      nil ->
        conn
        |> put_flash(:error, "Not impersonating anyone.")
        |> redirect(to: ~p"/")

      admin_email ->
        admin_workspace_slug = get_session(conn, @impersonator_workspace_key)
        impersonated_email = Auth.current_user(conn)

        Dran.Log.create(%{
          action: "impersonate.end",
          subject: "#{admin_email} <- #{impersonated_email}"
        })

        conn =
          conn
          |> delete_session(@impersonator_key)
          |> delete_session(@impersonator_workspace_key)
          # Restore the admin's session + workspace.
          |> Auth.login(admin_email, admin_workspace_slug)

        conn
        |> put_flash(:info, "Stopped impersonating.")
        |> redirect(to: ~p"/admin")
    end
  end

  # The target's landing workspace lives in Dran.Accounts.session_workspace_slug/1
  # — one resolver for login, mounts and impersonation. Nothing local here.
end
