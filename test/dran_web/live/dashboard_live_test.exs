defmodule DranWeb.DashboardLiveTest do
  use DranWeb.ConnCase, async: false

  # W1: the dashboard/workspace-launcher died with the multi-workspace model; / is the workspace home.
  @moduletag :skip

  alias Dran.Accounts
  alias Dran.Knowledge
  alias Dran.Repo

  # Gettext wrapper. English is the app default locale, so the msgid is
  # what the app renders unless a test pins another locale.
  defp t(msgid), do: Gettext.gettext(DranWeb.Gettext, msgid)

  # Deletes the account's personal workspace, simulating an account with no
  # workspaces at all (the shape of one created before personal workspaces
  # existed, or whose personal workspace was deleted).
  defp drop_personal_workspace(user) do
    user |> Accounts.personal_workspace() |> Knowledge.delete_workspace()
  end

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
      # The header shows instance totals (English is the default locale).
      assert html =~ "workspace"
      assert html =~ "page"
      # The default workspace is listed with a link into it
      assert html =~ ~s(href="/personal")
      assert html =~ "personal"
    end

    test "lists your own workspaces apart from the rest of the instance", %{conn: conn} do
      # A workspace test_user (the owner) is NOT a member of.
      {:ok, _other} = Knowledge.create_workspace(%{name: "Ajena", slug: "ajena"})

      {:ok, _view, html} = live(owner_conn(conn), ~p"/")

      assert html =~ t("Your workspaces")
      assert html =~ t("Organization")
      assert html =~ ~s(href="/personal")
      assert html =~ ~s(href="/ajena")
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

    test "rejects a name already in your own list, on the field", %{conn: conn} do
      {:ok, view, _html} = live(owner_conn(conn), ~p"/")

      Phoenix.LiveViewTest.render_click(view, "open_context_modal")

      view
      |> Phoenix.LiveViewTest.element("#context-form")
      |> Phoenix.LiveViewTest.render_submit(%{"context" => %{"name" => "Personal"}})

      # test_user is a member of the "personal" fixture, so that name is already
      # in their own list: the answer is a message, not a silent /personal-3f9a2b.
      modal =
        view |> Phoenix.LiveViewTest.element("#workspace-modal") |> Phoenix.LiveViewTest.render()

      assert modal =~ t("You already have a workspace with this name.")
      assert Enum.count(Knowledge.list_workspaces(), &(&1.name == "Personal")) == 1
    end

    test "the modal previews the slug it will really get, suffix included", %{conn: conn} do
      {:ok, view, _html} = live(owner_conn(conn), ~p"/")

      Phoenix.LiveViewTest.render_click(view, "open_context_modal")

      # A freshly opened modal is clean: nothing to complain about before typing.
      refute view
             |> Phoenix.LiveViewTest.element("#workspace-modal")
             |> Phoenix.LiveViewTest.render() =~
               "can't be blank"

      view
      |> Phoenix.LiveViewTest.element("#context-form")
      |> Phoenix.LiveViewTest.render_change(%{"context" => %{"name" => "Personal"}})

      # "personal" is taken by the fixture, so the honest preview carries the
      # suffix. It used to promise the bare slug and then create something else.
      modal =
        view |> Phoenix.LiveViewTest.element("#workspace-modal") |> Phoenix.LiveViewTest.render()

      assert modal =~ ~r|>personal-[0-9a-f]{6}</code>|
      refute modal =~ ~r|>personal</code>|
    end

    @tag :no_default_workspace
    test "empty instance shows the create CTA", %{conn: conn} do
      {:ok, owner} =
        Accounts.create_user(%{
          email: "owner@test.dev",
          name: "Owner",
          is_owner: true
        })

      # Every account is created with its own personal workspace, so the
      # instance is only truly empty for an account that has none.
      {:ok, _} = drop_personal_workspace(owner)

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

    test "never sees the Organization section, even for workspaces they cannot open", %{
      conn: conn
    } do
      {:ok, user} =
        Accounts.create_user(%{email: "member9@test.dev", name: "Member9", is_owner: false})

      ws = Knowledge.get_workspace_by_slug("personal")
      Accounts.add_user_to_workspace(user, ws)

      # A workspace they are not a member of: not theirs, and not reachable.
      {:ok, _other} = Knowledge.create_workspace(%{name: "Cerrada", slug: "cerrada"})

      {:ok, _view, html} = live(user_conn(conn, "member9@test.dev"), ~p"/")

      assert html =~ t("Your workspaces")
      refute html =~ t("Organization")
      refute html =~ ~s(href="/cerrada")
    end

    @tag :no_default_workspace
    test "with no memberships nor public workspaces shows the empty state", %{conn: conn} do
      {:ok, user} =
        Accounts.create_user(%{
          email: "none@test.dev",
          name: "Nobody",
          is_owner: false
        })

      # The account's personal workspace is its own silo, so "nothing assigned"
      # only happens for an account without one.
      {:ok, _} = drop_personal_workspace(user)

      # A private workspace the user is not a member of
      {:ok, _ws} =
        Knowledge.create_workspace(%{name: "Privada", slug: "privada", visibility: "private"})

      {:ok, _view, html} = live(user_conn(conn, "none@test.dev"), ~p"/")

      assert html =~ t("No workspaces assigned")
      refute html =~ t("New workspace")
    end
  end

  describe "access control" do
    test "a non-member cannot open a workspace by URL", %{conn: conn} do
      {:ok, _user} =
        Accounts.create_user(%{email: "outside@test.dev", name: "Outside", is_owner: false})

      {:ok, _ws} = Knowledge.create_workspace(%{name: "Cerrada2", slug: "cerrada-2"})

      # Every workspace is private: no membership, no entry — even by URL.
      assert {:error, {:redirect, %{to: "/"}}} =
               live(user_conn(conn, "outside@test.dev"), ~p"/cerrada-2")
    end

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
