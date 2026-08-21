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
        # is_owner fail-closed) and reset to the target's default workspace
        # (or their first accessible workspace, or the global default).
        target_slug =
          target_default_workspace_slug(target_user) || Dran.Auth.default_workspace_slug()

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

  # The target's default workspace (their configured default if they still
  # have access, otherwise their first accessible workspace, otherwise nil).
  defp target_default_workspace_slug(%{default_workspace_slug: slug} = user)
       when is_binary(slug) and slug != "" do
    case Dran.Knowledge.get_workspace_by_slug(slug) do
      %{} = _ws ->
        # Verify it's actually accessible to the target.
        if slug in Enum.map(Dran.Accounts.accessible_workspaces(user), & &1.slug) do
          slug
        else
          first_accessible_slug(user)
        end

      nil ->
        first_accessible_slug(user)
    end
  end

  defp target_default_workspace_slug(user), do: first_accessible_slug(user)

  defp first_accessible_slug(user) do
    case Dran.Accounts.accessible_workspaces(user) do
      [%{slug: slug} | _] -> slug
      _ -> nil
    end
  end
end
