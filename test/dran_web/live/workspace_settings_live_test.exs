defmodule DranWeb.WorkspaceSettingsLiveTest do
  use DranWeb.ConnCase, async: false

  alias Dran.Accounts
  alias Dran.DataCase

  # Gettext wrapper. English is the app default locale, so the msgid is what the
  # app renders unless a test pins another locale.
  defp t(msgid), do: Gettext.gettext(DranWeb.Gettext, msgid)

  defp uniq, do: System.unique_integer([:positive])

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

  describe "Users tab — quién puede agregar a quién" do
    # Dran no invita por correo (no hay envío de emails: `Dran.Mailer` no tiene
    # un solo llamador): agregar gente es meter una cuenta que YA existe en un
    # workspace. Las tres puertas que quedan son el creador/dueño del workspace
    # y el admin de la instancia.
    test "el creador del workspace agrega gente a la suya", %{conn: conn} do
      unique = uniq()

      {:ok, creator} =
        Accounts.create_user_with_password(%{
          email: "creador-#{unique}@example.com",
          password: "creador-larga-123"
        })

      # create_workspace_for/2 leaves the creator as `owner` of the workspace in
      # the same transaction — hence `owner_user_id`.
      {:ok, ws} =
        Dran.Knowledge.create_workspace(
          %{name: "Mío #{unique}", slug: "mio-#{unique}"},
          owner_user_id: creator.id
        )

      assert Accounts.user_role_in_workspace(creator, ws) == "owner"

      {:ok, invitee} = Accounts.create_user(%{email: "invitado-creador-#{unique}@example.com"})

      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session(:user, creator.email)
        |> Plug.Conn.put_session(:workspace_slug, ws.slug)
        |> Plug.Conn.put_session(:is_owner, false)

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/settings")
      open_users_tab(view)

      view
      |> element("#invite-member-form")
      |> render_submit(%{"invite" => %{"email" => invitee.email, "role" => "editor"}})

      assert Accounts.user_in_workspace?(invitee, ws)
      assert Accounts.user_role_in_workspace(invitee, ws) == "editor"
    end

    test "el admin de la instancia agrega a un workspace del que NO es miembro", %{conn: conn} do
      unique = uniq()

      # Sin `owner_user_id`: nadie del fixture es miembro de este workspace.
      {:ok, ws} =
        Dran.Knowledge.create_workspace(%{name: "Ajena #{unique}", slug: "ajena-#{unique}"})

      admin = Accounts.get_user_by_email("test_user")
      refute Accounts.user_in_workspace?(admin, ws)

      {:ok, invitee} = Accounts.create_user(%{email: "invitado-admin-#{unique}@example.com"})

      {:ok, view, _html} = live(admin_conn(conn, ws.slug), ~p"/#{ws.slug}/settings")
      open_users_tab(view)

      view
      |> element("#invite-member-form")
      |> render_submit(%{"invite" => %{"email" => invitee.email}})

      assert Accounts.user_in_workspace?(invitee, ws)
    end

    test "un miembro con rol editor NO entra a la pestaña de gente", %{conn: conn} do
      unique = uniq()
      ws = DataCase.ensure_workspace!()
      {:ok, editor} = Accounts.create_user(%{email: "editor-#{unique}@example.com"})
      {:ok, _} = Accounts.add_user_to_workspace(editor, ws, "editor")

      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session(:user, editor.email)
        |> Plug.Conn.put_session(:workspace_slug, ws.slug)
        |> Plug.Conn.put_session(:is_owner, false)

      # Un editor trabaja EN el workspace; quién entra y con qué rol es
      # configuración, y eso es de owner/admin (o del admin de la instancia).
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/#{ws.slug}/settings")
    end
  end
end
