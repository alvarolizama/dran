defmodule DranWeb.WorkspaceSettingsLiveTest do
  use DranWeb.ConnCase, async: false

  alias Dran.Accounts
  alias Dran.DataCase

  # Gettext wrapper. English is the app default locale, so the msgid is what the
  # app renders unless a test pins another locale.
  defp t(msgid), do: Gettext.gettext(DranWeb.Gettext, msgid)

  # The fixture session user ("test_user") is the instance owner, so the
  # :workspace_admin pipeline lets it into any workspace's settings.
  defp admin_conn(conn, slug) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:user, "test_user")
    |> Plug.Conn.put_session(:workspace_slug, slug)
    |> Plug.Conn.put_session(:is_owner, true)
  end

  defp open_users_tab(view) do
    view |> element(~s{button[phx-value-tab="users"]}) |> render_click()
  end

  describe "Users tab — adding an existing account" do
    test "adds the account with the picked role", %{conn: conn} do
      ws = DataCase.ensure_workspace!()
      {:ok, member} = Accounts.create_user(%{email: "invitee@example.com", name: "Invitee"})

      {:ok, view, _html} = live(admin_conn(conn, ws.slug), ~p"/#{ws.slug}/settings")
      open_users_tab(view)

      html =
        view
        |> element("#invite-member-form")
        |> render_submit(%{"invite" => %{"email" => "invitee@example.com", "role" => "editor"}})

      # The member list is re-rendered with the new member.
      assert html =~ "invitee@example.com"
      assert Accounts.user_in_workspace?(member, ws)
      assert Accounts.user_role_in_workspace(member, ws) == "editor"
    end

    test "refuses an email with no account — Dran has no invitation emails", %{conn: conn} do
      ws = DataCase.ensure_workspace!()

      {:ok, view, _html} = live(admin_conn(conn, ws.slug), ~p"/#{ws.slug}/settings")
      open_users_tab(view)

      html =
        view
        |> element("#invite-member-form")
        |> render_submit(%{"invite" => %{"email" => "ghost@example.com", "role" => "viewer"}})

      assert html =~
               t(
                 "No account with that email exists on this instance. Only existing users can be added."
               )

      refute Accounts.get_user_by_email("ghost@example.com")
    end

    test "reports an existing membership instead of failing", %{conn: conn} do
      ws = DataCase.ensure_workspace!()
      {:ok, member} = Accounts.create_user(%{email: "dup@example.com", name: "Dup"})
      {:ok, _} = Accounts.add_user_to_workspace(member, ws)

      {:ok, view, _html} = live(admin_conn(conn, ws.slug), ~p"/#{ws.slug}/settings")
      open_users_tab(view)

      html =
        view
        |> element("#invite-member-form")
        |> render_submit(%{"invite" => %{"email" => "dup@example.com", "role" => "viewer"}})

      assert html =~ t("That user already has access to this workspace.")
    end

    test "is refused for a user with no role in the workspace", %{conn: conn} do
      ws = DataCase.ensure_workspace!()
      {:ok, _outsider} = Accounts.create_user(%{email: "outside@example.com", name: "Outside"})

      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session(:user, "outside@example.com")
        |> Plug.Conn.put_session(:workspace_slug, ws.slug)
        |> Plug.Conn.put_session(:is_owner, false)

      # The :workspace_admin pipeline bounces them out of the settings page.
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/#{ws.slug}/settings")
    end
  end
end
