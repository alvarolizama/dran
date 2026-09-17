defmodule DranWeb.InstanceShellTest do
  @moduledoc """
  The three instance-level options — Workspaces (`/`), Account
  (`/settings/*`) and Admin (`/admin/*`) — share one shell-less layout: no
  sidebar, with the options menu pinned top-right.
  """

  use DranWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Dran.Accounts

  defp owner_conn(conn, email) do
    case Accounts.get_user_by_email(email) do
      nil ->
        {:ok, _user} =
          Accounts.create_user(%{email: email, name: "Test Owner", is_owner: true})

      _user ->
        :ok
    end

    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:user, email)
    |> Plug.Conn.put_session(:workspace_slug, "personal")
    |> Plug.Conn.put_session(:is_owner, true)
  end

  # {path, id of the option that must be marked as current}
  @pages [
    {"/", "topbar-dashboard"},
    {"/settings/account", "topbar-account"},
    {"/settings/api-keys", "topbar-account"},
    {"/admin", "topbar-admin"},
    {"/admin/users", "topbar-admin"},
    {"/admin/workspaces", "topbar-admin"},
    {"/admin/models", "topbar-admin"},
    {"/admin/system", "topbar-admin"},
    {"/admin/jobs", "topbar-admin"}
  ]

  for {path, active_id} <- @pages do
    test "#{path} renders the shell-less layout with #{active_id} active", %{conn: conn} do
      conn = owner_conn(conn, "shell_owner@test.dev")
      {:ok, view, html} = live(conn, unquote(path))

      # No sidebar — the `aside` was the old shell's left column.
      refute has_element?(view, "aside")
      refute html =~ "w-64 shrink-0"

      # The options menu lives in the top bar, with the three options.
      assert has_element?(view, "#app-topbar")
      assert has_element?(view, "#topbar-dashboard")
      assert has_element?(view, "#topbar-account")
      assert has_element?(view, "#topbar-admin")

      # The current option is marked; the others are not.
      assert has_element?(view, "##{unquote(active_id)}[aria-current=\"page\"]")

      for id <- ["topbar-dashboard", "topbar-account", "topbar-admin"],
          id != unquote(active_id) do
        refute has_element?(view, "##{id}[aria-current=\"page\"]")
      end
    end
  end

  test "the Admin option is hidden for non-owners", %{conn: conn} do
    {:ok, _user} =
      Accounts.create_user(%{email: "shell_plain@test.dev", name: "Plain", is_owner: false})

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user, "shell_plain@test.dev")
      |> Plug.Conn.put_session(:is_owner, false)

    {:ok, view, _html} = live(conn, ~p"/settings/account")

    assert has_element?(view, "#app-topbar")
    assert has_element?(view, "#topbar-dashboard")
    assert has_element?(view, "#topbar-account")
    refute has_element?(view, "#topbar-admin")
  end
end
