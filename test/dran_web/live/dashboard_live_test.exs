defmodule DranWeb.DashboardLiveTest do
  use DranWeb.ConnCase, async: false

  alias Dran.Accounts
  alias Dran.Knowledge
  alias Dran.Repo

  # Gettext wrapper — the app default locale is "es", so assertions must
  # match the translated strings, not the English msgids.
  defp t(msgid), do: Gettext.gettext(DranWeb.Gettext, msgid)

  defp owner_conn(conn) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:user, "test_user")
    |> Plug.Conn.put_session(:workspace_slug, "personal")
    |> Plug.Conn.put_session(:is_owner, true)
  end

  defp user_conn(conn, email) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:user, email)
    |> Plug.Conn.put_session(:workspace_slug, "personal")
    |> Plug.Conn.put_session(:is_owner, false)
  end

  setup %{conn: conn} do
    # Disable inference so create_page doesn't call external APIs
    original = Application.get_env(:dran, :inference)

    Application.put_env(:dran, :inference,
      base_url: nil,
      api_key: nil,
      embedding_model: nil,
      rerank_model: nil,
      timeout: 100,
      schedule_async: false
    )

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:dran, :inference)
      else
        Application.put_env(:dran, :inference, original)
      end
    end)

    {:ok, conn: conn}
  end

  setup tags do
    if tags[:no_default_workspace] do
      # Empty-instance tests need ZERO workspaces. The test DB can carry
      # leftovers written outside the sandbox (smoke runs); purge inside
      # the sandbox transaction — rollback restores everything after.
      Repo.query!("TRUNCATE TABLE workspaces CASCADE")
    end

    :ok
  end

  describe "instance dashboard (owner)" do
    test "shows instance header counts, workspace cards and the New workspace button", %{
      conn: conn
    } do
      {:ok, _view, html} = live(owner_conn(conn), ~p"/")

      assert html =~ t("Dashboard")
      assert html =~ t("New workspace")
      # The header shows instance totals (es locale renders the translations).
      assert html =~ "espacio de trabajo"
      assert html =~ "página"
      # The default workspace is listed with a link into it
      assert html =~ ~s(href="/personal")
      assert html =~ "personal"
    end

    test "creates a workspace from the modal", %{conn: conn} do
      {:ok, view, html} = live(owner_conn(conn), ~p"/")

      refute html =~ "nuevo-ws"

      html = Phoenix.LiveViewTest.render_click(view, "open_context_modal")
      assert html =~ "context-form"

      html =
        view
        |> Phoenix.LiveViewTest.element("#context-form")
        |> Phoenix.LiveViewTest.render_submit(%{"context" => %{"name" => "Nuevo WS"}})

      assert html =~ "nuevo-ws"
      assert Phoenix.LiveViewTest.render(view) =~ t("Workspace created")
    end

    @tag :no_default_workspace
    test "empty instance shows the create CTA", %{conn: conn} do
      {:ok, _owner} =
        Accounts.create_user(%{
          email: "owner@test.dev",
          name: "Owner",
          is_owner: true
        })

      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session(:user, "owner@test.dev")
        |> Plug.Conn.put_session(:is_owner, true)

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ t("No workspaces yet")
      assert html =~ t("New workspace")
    end
  end

  describe "regular user (non-admin)" do
    test "sees their accessible workspaces but never the create button", %{conn: conn} do
      {:ok, user} =
        Accounts.create_user(%{
          email: "member@test.dev",
          name: "Member",
          is_owner: false
        })

      ws = Knowledge.get_workspace_by_slug("personal")
      Accounts.add_user_to_workspace(user, ws)

      {:ok, _view, html} = live(user_conn(conn, "member@test.dev"), ~p"/")

      assert html =~ t("Your workspaces")
      assert html =~ ~s(href="/personal")
      refute html =~ t("New workspace")
      refute html =~ t("Users")
    end

    @tag :no_default_workspace
    test "with no memberships nor public workspaces shows the empty state", %{conn: conn} do
      {:ok, _user} =
        Accounts.create_user(%{
          email: "none@test.dev",
          name: "Nobody",
          is_owner: false
        })

      # A private workspace the user is not a member of
      {:ok, _ws} =
        Knowledge.create_workspace(%{name: "Privada", slug: "privada", visibility: "private"})

      {:ok, _view, html} = live(user_conn(conn, "none@test.dev"), ~p"/")

      assert html =~ t("No workspaces assigned")
      refute html =~ t("New workspace")
    end
  end

  describe "access control" do
    test "create_workspace event is rejected for non-owners", %{conn: conn} do
      {:ok, user} =
        Accounts.create_user(%{
          email: "member2@test.dev",
          name: "Member2",
          is_owner: false
        })

      ws = Knowledge.get_workspace_by_slug("personal")
      Accounts.add_user_to_workspace(user, ws)

      {:ok, view, _html} = live(user_conn(conn, "member2@test.dev"), ~p"/")

      # Force the event server-side (bypasses the hidden button)
      html =
        Phoenix.LiveViewTest.render_submit(view, "create_workspace", %{
          "context" => %{"name" => "Sneaky WS"}
        })

      assert html =~ t("Insufficient permissions")
      refute Knowledge.get_workspace_by_slug("sneaky-ws")
    end
  end
end
