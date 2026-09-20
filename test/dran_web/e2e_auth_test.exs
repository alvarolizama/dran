defmodule DranWeb.E2EAuthTest do
  use DranWeb.ConnCase, async: false

  alias Dran.{Accounts, Knowledge}

  setup %{conn: conn} do
    # Create owner user
    {:ok, admin} =
      Accounts.create_user(%{
        email: "admin@example.com",
        name: "Admin",
        is_owner: true
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

    {:ok, ctx1} =
      Knowledge.create_workspace(%{name: "Personal #{unique}", slug: "personal-#{unique}"})

    {:ok, ctx2} =
      Knowledge.create_workspace(%{
        name: "Work #{unique}",
        slug: "work-#{unique}",
        # F2: ctx2 must be private to still test the restrict-access path;
        # with the old default (public), accessible_workspaces broadens access
        # and the 403 assertion no longer holds.
        visibility: "private"
      })

    # Assign user to only the personal context
    Accounts.add_user_to_workspace(user, ctx1)

    {:ok, conn: conn, admin: admin, user: user, ctx1: ctx1, ctx2: ctx2}
  end

  test "owner can access all contexts", %{admin: admin, ctx1: _ctx1, ctx2: _ctx2} do
    assert Accounts.is_owner?(admin)

    # Creating the owner created the owner's OWN personal workspace, so that is
    # the only membership it has. "The owner reaches every workspace" is a rule
    # of require_workspace_access/2, not of list_user_workspaces/1.
    assert [personal] = Accounts.list_user_workspaces(admin)
    assert personal.id == admin.personal_workspace_id
  end

  test "regular user only sees assigned contexts", %{user: user, ctx1: ctx1, ctx2: ctx2} do
    contexts = Accounts.list_user_workspaces(user)

    # The account's own personal workspace (created with it) plus the one it was
    # assigned to — and neither of them is the private context it has no
    # membership in.
    assert Enum.map(contexts, & &1.id) |> Enum.sort() ==
             Enum.sort([user.personal_workspace_id, ctx1.id])

    refute Enum.map(contexts, & &1.id) |> Enum.member?(ctx2.id)
  end

  test "user api_token works for all assigned contexts", %{user: user, ctx1: ctx1} do
    assert {:ok, authed} = Accounts.valid_token?(user.api_token)
    assert authed.id == user.id
    assert Enum.map(authed.workspaces, & &1.id) |> Enum.member?(ctx1.id)
  end

  test "unknown api_token is rejected", %{} do
    assert Accounts.valid_token?("bogus-token") == :error
  end

  test "legacy admin token works when configured, disabled otherwise", %{} do
    # With no token configured (default), the legacy admin token is disabled
    # and any bearer is rejected by Dran.Auth.valid_token?/1.
    refute Dran.Auth.valid_token?("invalid-token")

    Dran.Settings.put("api_token", "test-legacy-token")
    assert Dran.Auth.valid_token?("test-legacy-token")
    refute Dran.Auth.valid_token?("invalid-token")
  end

  test "REST restricts regular user to their assigned context", %{
    conn: conn,
    user: user,
    ctx2: ctx2
  } do
    assert {:ok, _} = Accounts.valid_token?(user.api_token)

    # A workspace the user does NOT have access to must be forbidden.
    conn =
      conn
      |> Plug.Conn.put_req_header("authorization", "Bearer #{user.api_token}")
      |> Plug.Conn.put_req_header("accept", "application/json")
      |> Phoenix.ConnTest.get("/api/workspaces/#{ctx2.slug}/export")

    assert conn.status == 403
  end

  test "REST allows regular user access to their assigned context", %{
    conn: conn,
    user: user,
    ctx1: ctx1
  } do
    # The agent surface (plugin tools → REST) must serve a context the user
    # can access.
    conn =
      conn
      |> Plug.Conn.put_req_header("authorization", "Bearer #{user.api_token}")
      |> Plug.Conn.put_req_header("accept", "application/json")
      |> Phoenix.ConnTest.get("/api/knowledge-pages?workspace=#{ctx1.slug}")

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) |> Map.has_key?("data")
  end

  describe "context-scoped API keys" do
    test "create_api_key returns plaintext token once, stores only hash + prefix", %{ctx1: ctx1} do
      {:ok, key} = Accounts.create_api_key(%{name: "Hermes", workspace_id: ctx1.id})

      assert is_binary(key.token)
      assert String.length(key.token) > 30
      assert key.token_prefix == String.slice(key.token, 0, 8)
      assert key.token_hash == Accounts.ApiKey.hash_token(key.token)
      refute key.token_hash == key.token
    end

    test "valid_api_key? accepts active keys and preloads the context", %{ctx1: ctx1} do
      {:ok, key} = Accounts.create_api_key(%{name: "Hermes", workspace_id: ctx1.id})

      assert {:ok, found} = Accounts.valid_api_key?(key.token)
      assert found.id == key.id
      assert Enum.any?(found.api_key_workspaces, &(&1.workspace.slug == ctx1.slug))
    end

    test "revoked keys fail validation, restored keys work again", %{ctx1: ctx1} do
      {:ok, key} = Accounts.create_api_key(%{name: "Hermes", workspace_id: ctx1.id})

      {:ok, revoked} = Accounts.revoke_api_key(key)
      assert revoked.revoked_at
      assert Accounts.valid_api_key?(key.token) == :error

      {:ok, _} = Accounts.restore_api_key(revoked)
      assert {:ok, _} = Accounts.valid_api_key?(key.token)
    end

    test "regenerate_api_key invalidates the old token and returns a new one", %{ctx1: ctx1} do
      {:ok, key} = Accounts.create_api_key(%{name: "Hermes", workspace_id: ctx1.id})
      old_token = key.token

      {:ok, regenerated} = Accounts.regenerate_api_key(key)
      assert regenerated.token != old_token

      assert Accounts.valid_api_key?(old_token) == :error
      assert {:ok, _} = Accounts.valid_api_key?(regenerated.token)
    end

    test "regenerating a revoked key reactivates it", %{ctx1: ctx1} do
      {:ok, key} = Accounts.create_api_key(%{name: "Hermes", workspace_id: ctx1.id})
      {:ok, revoked} = Accounts.revoke_api_key(key)

      {:ok, regenerated} = Accounts.regenerate_api_key(revoked)
      assert is_nil(regenerated.revoked_at)
      assert {:ok, _} = Accounts.valid_api_key?(regenerated.token)
    end

    test "REST accepts a context API key for its own context", %{
      conn: conn,
      ctx1: ctx1
    } do
      {:ok, key} = Accounts.create_api_key(%{name: "Hermes", workspace_id: ctx1.id})

      conn =
        conn
        |> Plug.Conn.put_req_header("authorization", "Bearer #{key.token}")
        |> Plug.Conn.put_req_header("accept", "application/json")
        |> Phoenix.ConnTest.get("/api/knowledge-pages?workspace=#{ctx1.slug}")

      assert conn.status == 200
    end

    test "REST rejects a context API key used against a DIFFERENT context", %{
      conn: conn,
      ctx1: ctx1,
      ctx2: ctx2
    } do
      {:ok, key} = Accounts.create_api_key(%{name: "Hermes", workspace_id: ctx1.id})

      conn =
        conn
        |> Plug.Conn.put_req_header("authorization", "Bearer #{key.token}")
        |> Plug.Conn.put_req_header("accept", "application/json")
        |> Phoenix.ConnTest.get("/api/knowledge-pages?workspace=#{ctx2.slug}")

      assert conn.status == 403
    end

    test "REST rejects a revoked key", %{conn: conn, ctx1: ctx1} do
      {:ok, key} = Accounts.create_api_key(%{name: "Hermes", workspace_id: ctx1.id})
      {:ok, _} = Accounts.revoke_api_key(key)

      conn =
        conn
        |> Plug.Conn.put_req_header("authorization", "Bearer #{key.token}")
        |> Plug.Conn.put_req_header("accept", "application/json")
        |> Phoenix.ConnTest.get("/api/knowledge-pages?workspace=#{ctx1.slug}")

      assert conn.status == 401
    end

    test "deleting a context revokes API keys whose last workspace it was", %{ctx1: ctx1} do
      {:ok, key} = Accounts.create_api_key(%{name: "Hermes", workspace_id: ctx1.id})

      {:ok, _} = Knowledge.delete_workspace(ctx1)

      # Multi-workspace model: the join rows cascade away, and a key left
      # with zero workspaces is revoked (not deleted) so the audit trail
      # survives. The token must stop working immediately.
      assert Accounts.valid_api_key?(key.token) == :error
      revoked = Dran.Repo.reload!(key)
      assert revoked.revoked_at
    end

    test "new API key defaults to read-only (write_access=false)", %{ctx1: ctx1} do
      {:ok, key} = Accounts.create_api_key(%{name: "Reader", workspace_id: ctx1.id})
      refute Dran.Accounts.ApiKey.write_access?(key)
    end

    test "create_api_key with write_access: true", %{ctx1: ctx1} do
      {:ok, key} =
        Accounts.create_api_key(%{name: "Writer", workspace_id: ctx1.id, write_access: true})

      assert Dran.Accounts.ApiKey.write_access?(key)
    end

    test "update_api_key toggles write_access", %{ctx1: ctx1} do
      {:ok, key} = Accounts.create_api_key(%{name: "Reader", workspace_id: ctx1.id})
      refute Dran.Accounts.ApiKey.write_access?(key)

      {:ok, updated} = Accounts.update_api_key(key, %{write_access: true})
      assert Dran.Accounts.ApiKey.write_access?(updated)

      {:ok, updated2} = Accounts.update_api_key(updated, %{write_access: false})
      refute Dran.Accounts.ApiKey.write_access?(updated2)
    end

    test "REST read-only key can call read routes (search)", %{conn: conn, ctx1: ctx1} do
      {:ok, key} = Accounts.create_api_key(%{name: "Reader", workspace_id: ctx1.id})

      conn =
        conn
        |> Plug.Conn.put_req_header("authorization", "Bearer #{key.token}")
        |> Plug.Conn.put_req_header("accept", "application/json")
        |> Phoenix.ConnTest.get("/api/search?q=test&workspace=#{ctx1.slug}")

      assert conn.status == 200
    end
  end

  describe "write_access enforcement — REST" do
    test "read-only key is blocked from creating a page", %{conn: conn, ctx1: ctx1} do
      {:ok, key} = Accounts.create_api_key(%{name: "Reader", workspace_id: ctx1.id})

      conn =
        conn
        |> Plug.Conn.put_req_header("authorization", "Bearer #{key.token}")
        |> Plug.Conn.put_req_header("accept", "application/json")
        |> Phoenix.ConnTest.post("/api/knowledge-pages", %{
          "workspace" => ctx1.slug,
          "page_type" => "note",
          "title" => "Test"
        })

      assert conn.status == 403
    end

    test "read-only key is blocked from storing memory", %{conn: conn, ctx1: ctx1} do
      {:ok, key} = Accounts.create_api_key(%{name: "Reader", workspace_id: ctx1.id})

      conn =
        conn
        |> Plug.Conn.put_req_header("authorization", "Bearer #{key.token}")
        |> Plug.Conn.put_req_header("accept", "application/json")
        |> Phoenix.ConnTest.post("/api/memory", %{
          "workspace" => ctx1.slug,
          "content" => "un hecho"
        })

      assert conn.status == 403
    end

    test "write-enabled key can create a page", %{conn: conn, ctx1: ctx1} do
      {:ok, key} =
        Accounts.create_api_key(%{name: "Writer", workspace_id: ctx1.id, write_access: true})

      conn =
        conn
        |> Plug.Conn.put_req_header("authorization", "Bearer #{key.token}")
        |> Plug.Conn.put_req_header("accept", "application/json")
        |> Phoenix.ConnTest.post("/api/knowledge-pages", %{
          "workspace" => ctx1.slug,
          "page_type" => "note",
          "title" => "Write test",
          "slug" => "write-test-#{System.unique_integer([:positive])}"
        })

      assert conn.status == 201
      assert Jason.decode!(conn.resp_body)["data"]["slug"]
    end

    test "legacy admin token bypasses write_access check", %{conn: conn, ctx1: ctx1} do
      Dran.Settings.put("api_token", "test-legacy-admin-token")

      conn =
        conn
        |> Plug.Conn.put_req_header("authorization", "Bearer test-legacy-admin-token")
        |> Plug.Conn.put_req_header("accept", "application/json")
        |> Phoenix.ConnTest.post("/api/knowledge-pages", %{
          "workspace" => ctx1.slug,
          "page_type" => "note",
          "title" => "Admin test",
          "slug" => "admin-test-#{System.unique_integer([:positive])}"
        })

      assert conn.status == 201
    end
  end

  describe "per-user default context" do
    test "set_default_context persists the slug", %{user: user, ctx2: ctx2} do
      {:ok, updated} = Accounts.set_default_context(user, ctx2.slug)
      assert updated.default_workspace_slug == ctx2.slug

      reloaded = Accounts.get_user!(user.id)
      assert reloaded.default_workspace_slug == ctx2.slug
    end
  end

  describe "sidebar integration" do
    test "workspace CRUD lives in /admin/workspaces", %{
      conn: conn,
      admin: admin,
      ctx1: ctx1
    } do
      conn =
        conn
        |> init_test_session(%{user: admin.email, workspace_slug: ctx1.slug, is_owner: true})

      {:ok, view, html} = Phoenix.LiveViewTest.live(conn, ~p"/admin/workspaces")

      # The workspaces table lists existing workspaces and their controls
      assert html =~ ctx1.slug
      # Manage users button per workspace
      assert html =~ "manage_workspace_users"

      # Opening the "New workspace" modal exposes the create form
      html = Phoenix.LiveViewTest.render_click(view, "new_workspace")
      assert html =~ "workspace-form"
    end

    test "manage users modal opens with user checkboxes", %{
      conn: conn,
      admin: admin,
      user: user,
      ctx1: ctx1
    } do
      conn =
        conn
        |> init_test_session(%{user: admin.email, workspace_slug: ctx1.slug, is_owner: true})

      {:ok, view, _html} = Phoenix.LiveViewTest.live(conn, ~p"/admin/workspaces")

      # Open the modal for ctx1
      html = Phoenix.LiveViewTest.render_click(view, "manage_workspace_users", %{"id" => ctx1.id})

      # Modal shows users with checkboxes
      assert html =~ "toggle_workspace_user"
      assert html =~ user.email
      assert html =~ "close_workspace_users"

      # Close the modal
      html = Phoenix.LiveViewTest.render_click(view, "close_workspace_users")
      refute html =~ "toggle_workspace_user"
    end

    # W1 single-workspace: no ctx-per-user scoping left. The admin sees the
    # instance links from any workspace page; /admin/workspaces still lists
    # the (single) workspace row for the owner.
    test "admin session sees the sidebars links and all workspaces", %{
      conn: conn,
      admin: admin,
      ctx1: ctx1,
      ctx2: ctx2
    } do
      conn =
        conn
        |> init_test_session(%{user: admin.email, workspace_slug: ctx1.slug, is_owner: true})

      # Workspace page: the admin sees the instance settings link.
      {:ok, _view, html} = Phoenix.LiveViewTest.live(conn, ~p"/notes")
      assert html =~ ~p"/settings/instance"
      assert html =~ ~p"/activity"

      # The workspace home carries the account links.
      {:ok, _view, dash_html} = Phoenix.LiveViewTest.live(conn, ~p"/")
      assert dash_html =~ ~p"/settings/account"

      # /admin/workspaces lists every (folded) workspace row for the owner
      {:ok, _view, ws_html} = Phoenix.LiveViewTest.live(conn, ~p"/admin/workspaces")
      assert ws_html =~ ctx1.slug
      assert ws_html =~ ctx2.slug
    end

    test "non-admin session hides the Settings link and only sees assigned contexts", %{
      conn: conn,
      user: user,
      ctx1: ctx1,
      ctx2: ctx2
    } do
      conn =
        conn
        |> init_test_session(%{user: user.email, workspace_slug: ctx1.slug})

      # W1 single-workspace: any logged-in user reaches the flat routes —
      # per-workspace gating died with the multi-workspace model (per-item
      # visibility lands in W2/W3).
      assert {:ok, _view, _html} = Phoenix.LiveViewTest.live(conn, ~p"/notes")
    end
  end
end
