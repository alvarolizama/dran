defmodule DranWeb.E2EAuthTest do
  use DranWeb.ConnCase, async: false

  alias Dran.{Accounts, Brain}

  setup %{conn: conn} do
    # Create admin user
    {:ok, admin} =
      Accounts.create_user(%{
        email: "admin@example.com",
        name: "Admin",
        is_admin: true
      })

    # Create regular user with limited contexts
    {:ok, user} =
      Accounts.create_user(%{
        email: "user@example.com",
        name: "Regular User"
      })

    # Create contexts — use unique slugs/names so they don't collide with
    # fixtures created by other async:false tests sharing this database.
    unique = System.unique_integer([:positive])
    {:ok, ctx1} = Brain.create_context(%{name: "Personal #{unique}", slug: "personal-#{unique}"})
    {:ok, ctx2} = Brain.create_context(%{name: "Work #{unique}", slug: "work-#{unique}"})

    # Assign user to only the personal context
    Accounts.add_user_to_context(user, ctx1)

    {:ok, conn: conn, admin: admin, user: user, ctx1: ctx1, ctx2: ctx2}
  end

  test "admin can access all contexts", %{admin: admin, ctx1: _ctx1, ctx2: _ctx2} do
    assert Accounts.is_admin?(admin)
    assert Accounts.list_user_contexts(admin) == []
  end

  test "regular user only sees assigned contexts", %{user: user, ctx1: ctx1, ctx2: ctx2} do
    contexts = Accounts.list_user_contexts(user)
    assert length(contexts) == 1
    assert hd(contexts).id == ctx1.id
    refute Enum.map(contexts, & &1.id) |> Enum.member?(ctx2.id)
  end

  test "user api_token works for all assigned contexts", %{user: user, ctx1: ctx1} do
    assert {:ok, authed} = Accounts.valid_token?(user.api_token)
    assert authed.id == user.id
    assert Enum.map(authed.contexts, & &1.id) |> Enum.member?(ctx1.id)
  end

  test "unknown api_token is rejected", %{} do
    assert Accounts.valid_token?("bogus-token") == :error
  end

  test "legacy admin token still works", %{} do
    # DRAN_API_TOKEN should still work and be accepted by the MCP controller
    assert Dran.Auth.valid_token?(Dran.Auth.api_token())
    refute Dran.Auth.valid_token?("invalid-token")
  end

  test "MCP restricts regular user to their assigned context", %{
    conn: conn,
    user: user,
    ctx2: ctx2
  } do
    assert {:ok, _} = Accounts.valid_token?(user.api_token)

    # Request a context the user does NOT have access to must be forbidden
    conn =
      conn
      |> Plug.Conn.put_req_header("authorization", "Bearer #{user.api_token}")
      |> Plug.Conn.put_req_header("accept", "application/json")
      |> Phoenix.ConnTest.post("/api/mcp", %{"context" => ctx2.slug})

    assert conn.status == 403
  end

  test "MCP allows regular user access to their assigned context", %{
    conn: conn,
    user: user,
    ctx1: ctx1
  } do
    # A valid JSON-RPC request scoped to a context the user can access must
    # be accepted (200) and served.
    msg = %{"jsonrpc" => "2.0", "method" => "tools/list", "id" => 1, "context" => ctx1.slug}

    conn =
      conn
      |> Plug.Conn.put_req_header("authorization", "Bearer #{user.api_token}")
      |> Plug.Conn.put_req_header("accept", "application/json")
      |> Phoenix.ConnTest.post("/api/mcp", msg)

    assert conn.status == 200
    assert conn.resp_body =~ "tools"
  end

  describe "sidebar integration" do
    test "/contexts is admin-only", %{conn: conn, user: user, ctx1: ctx1} do
      conn =
        conn
        |> init_test_session(%{user: user.email, context_slug: ctx1.slug})

      # Non-admin is redirected away from /contexts
      assert {:error, {:redirect, %{to: "/"}}} = Phoenix.LiveViewTest.live(conn, ~p"/contexts")
    end

    test "admin session sees the Settings link and all contexts", %{
      conn: conn,
      admin: admin,
      ctx1: ctx1,
      ctx2: ctx2
    } do
      conn =
        conn
        |> init_test_session(%{user: admin.email, context_slug: ctx1.slug})

      {:ok, _view, html} = Phoenix.LiveViewTest.live(conn, ~p"/notes")

      # Admin sees the Settings link in the sidebar
      assert html =~ ~p"/settings"
      # Context selector includes both contexts (ctx2 was never assigned)
      assert html =~ ctx1.slug
      assert html =~ ctx2.slug
    end

    test "non-admin session hides the Settings link and only sees assigned contexts", %{
      conn: conn,
      user: user,
      ctx1: ctx1,
      ctx2: ctx2
    } do
      conn =
        conn
        |> init_test_session(%{user: user.email, context_slug: ctx1.slug})

      {:ok, _view, html} = Phoenix.LiveViewTest.live(conn, ~p"/notes")

      # Non-admin must NOT see the Settings link
      refute html =~ ~p"/settings"
      # Context selector shows only the assigned context, not ctx2
      assert html =~ ctx1.slug
      refute html =~ ctx2.slug
    end
  end
end
