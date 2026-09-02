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
    assert Accounts.list_user_workspaces(admin) == []
  end

  test "regular user only sees assigned contexts", %{user: user, ctx1: ctx1, ctx2: ctx2} do
    contexts = Accounts.list_user_workspaces(user)
    assert length(contexts) == 1
    assert hd(contexts).id == ctx1.id
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
      |> Phoenix.ConnTest.post("/api/mcp", %{"workspace" => ctx2.slug})

    assert conn.status == 403
  end

  test "MCP allows regular user access to their assigned context", %{
    conn: conn,
    user: user,
    ctx1: ctx1
  } do
    # A valid JSON-RPC request scoped to a context the user can access must
    # be accepted (200) and served.
    msg = %{"jsonrpc" => "2.0", "method" => "tools/list", "id" => 1, "workspace" => ctx1.slug}

    conn =
      conn
      |> Plug.Conn.put_req_header("authorization", "Bearer #{user.api_token}")
      |> Plug.Conn.put_req_header("accept", "application/json")
      |> Phoenix.ConnTest.post("/api/mcp", msg)

    assert conn.status == 200
    assert conn.resp_body =~ "tools"
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

    test "MCP accepts a context API key for its own context", %{
      conn: conn,
      ctx1: ctx1
    } do
      {:ok, key} = Accounts.create_api_key(%{name: "Hermes", workspace_id: ctx1.id})
      msg = %{"jsonrpc" => "2.0", "method" => "tools/list", "id" => 1, "workspace" => ctx1.slug}

      conn =
        conn
        |> Plug.Conn.put_req_header("authorization", "Bearer #{key.token}")
        |> Plug.Conn.put_req_header("accept", "application/json")
        |> Phoenix.ConnTest.post("/api/mcp", msg)

      assert conn.status == 200
    end

    test "MCP rejects a context API key used against a DIFFERENT context", %{
      conn: conn,
      ctx1: ctx1,
      ctx2: ctx2
    } do
      {:ok, key} = Accounts.create_api_key(%{name: "Hermes", workspace_id: ctx1.id})

      conn =
        conn
        |> Plug.Conn.put_req_header("authorization", "Bearer #{key.token}")
        |> Plug.Conn.put_req_header("accept", "application/json")
        |> Phoenix.ConnTest.post("/api/mcp", %{"workspace" => ctx2.slug})

      assert conn.status == 403
    end

    test "MCP rejects a revoked key", %{conn: conn, ctx1: ctx1} do
      {:ok, key} = Accounts.create_api_key(%{name: "Hermes", workspace_id: ctx1.id})
      {:ok, _} = Accounts.revoke_api_key(key)

      conn =
        conn
        |> Plug.Conn.put_req_header("authorization", "Bearer #{key.token}")
        |> Plug.Conn.put_req_header("accept", "application/json")
        |> Phoenix.ConnTest.post("/api/mcp", %{"workspace" => ctx1.slug})

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

    test "MCP read-only key can call read tools (search)", %{conn: conn, ctx1: ctx1} do
      {:ok, key} = Accounts.create_api_key(%{name: "Reader", workspace_id: ctx1.id})

      msg = %{
        "jsonrpc" => "2.0",
        "method" => "tools/call",
        "id" => 1,
        "params" => %{
          "name" => "dran_search",
          "arguments" => %{"query" => "test", "workspace" => ctx1.slug}
        }
      }

      conn =
        conn
        |> Plug.Conn.put_req_header("authorization", "Bearer #{key.token}")
        |> Plug.Conn.put_req_header("accept", "application/json")
        |> Phoenix.ConnTest.post("/api/mcp", msg)

      assert conn.status == 200
    end
  end

  describe "write_access enforcement — MCP" do
    test "read-only key is blocked from dran_create_page", %{conn: conn, ctx1: ctx1} do
      {:ok, key} = Accounts.create_api_key(%{name: "Reader", workspace_id: ctx1.id})

      msg = %{
        "jsonrpc" => "2.0",
        "method" => "tools/call",
        "id" => 1,
        "params" => %{
          "name" => "dran_create_page",
          "arguments" => %{"workspace" => ctx1.slug, "page_type" => "note", "title" => "Test"}
        }
      }

      conn =
        conn
        |> Plug.Conn.put_req_header("authorization", "Bearer #{key.token}")
        |> Plug.Conn.put_req_header("accept", "application/json")
        |> Phoenix.ConnTest.post("/api/mcp", msg)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["message"] =~ "read-only"
    end

    test "read-only key is blocked from dran_create_note", %{conn: conn, ctx1: ctx1} do
      {:ok, key} = Accounts.create_api_key(%{name: "Reader", workspace_id: ctx1.id})

      msg = %{
        "jsonrpc" => "2.0",
        "method" => "tools/call",
        "id" => 1,
        "params" => %{
          "name" => "dran_create_note",
          "arguments" => %{"workspace" => ctx1.slug, "title" => "T", "slug" => "t"}
        }
      }

      conn =
        conn
        |> Plug.Conn.put_req_header("authorization", "Bearer #{key.token}")
        |> Plug.Conn.put_req_header("accept", "application/json")
        |> Phoenix.ConnTest.post("/api/mcp", msg)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["message"] =~ "read-only"
    end

    test "write-enabled key can call dran_create_page", %{conn: conn, ctx1: ctx1} do
      {:ok, key} =
        Accounts.create_api_key(%{name: "Writer", workspace_id: ctx1.id, write_access: true})

      msg = %{
        "jsonrpc" => "2.0",
        "method" => "tools/call",
        "id" => 1,
        "params" => %{
          "name" => "dran_create_page",
          "arguments" => %{
            "workspace" => ctx1.slug,
            "page_type" => "note",
            "title" => "Write test",
            "slug" => "write-test-#{System.unique_integer([:positive])}"
          }
        }
      }

      conn =
        conn
        |> Plug.Conn.put_req_header("authorization", "Bearer #{key.token}")
        |> Plug.Conn.put_req_header("accept", "application/json")
        |> Phoenix.ConnTest.post("/api/mcp", msg)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      # No "error" key — the result is in "result"
      refute Map.has_key?(body, "error")
      assert body["result"]["content"]
    end

    test "legacy admin token bypasses write_access check", %{conn: conn, ctx1: ctx1} do
      msg = %{
        "jsonrpc" => "2.0",
        "method" => "tools/call",
        "id" => 1,
        "params" => %{
          "name" => "dran_create_page",
          "arguments" => %{
            "workspace" => ctx1.slug,
            "page_type" => "note",
            "title" => "Admin test",
            "slug" => "admin-test-#{System.unique_integer([:positive])}"
          }
        }
      }

      conn =
        conn
        |> Plug.Conn.put_req_header("authorization", "Bearer #{Dran.Auth.api_token()}")
        |> Plug.Conn.put_req_header("accept", "application/json")
        |> Phoenix.ConnTest.post("/api/mcp", msg)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      refute Map.has_key?(body, "error")
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

      # The workspaces table lists existing contexts and their controls
      assert html =~ ctx1.slug
      # Manage users button per workspace
      assert html =~ "manage_context_users"

      # Opening the "New context" modal exposes the create form
      html = Phoenix.LiveViewTest.render_click(view, "new_workspace")
      assert html =~ "context-form"
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
      html = Phoenix.LiveViewTest.render_click(view, "manage_context_users", %{"id" => ctx1.id})

      # Modal shows users with checkboxes
      assert html =~ "toggle_context_user"
      assert html =~ user.email
      assert html =~ "close_context_users"

      # Close the modal
      html = Phoenix.LiveViewTest.render_click(view, "close_context_users")
      refute html =~ "toggle_context_user"
    end

    test "admin session sees the sidebars links and all workspaces", %{
      conn: conn,
      admin: admin,
      ctx1: ctx1,
      ctx2: ctx2
    } do
      conn =
        conn
        |> init_test_session(%{user: admin.email, workspace_slug: ctx1.slug, is_owner: true})

      # Workspace-scoped page: admin sees the workspace Config link + Account (entry
      # point of the personal settings tabs, incl. API Keys) in the sidebar
      {:ok, _view, html} = Phoenix.LiveViewTest.live(conn, ~p"/#{ctx1.slug}/notes")
      assert html =~ ~p"/#{ctx1.slug}/settings"
      assert html =~ ~p"/settings/account"
      assert html =~ ~p"/admin"
      assert html =~ ctx1.slug

      # /admin/workspaces lists ALL workspaces for the instance owner
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

      # Viewer CAN access ctx1 — they are a member AND ctx1 is public.
      assert {:ok, _view, _html} = Phoenix.LiveViewTest.live(conn, ~p"/#{ctx1.slug}/notes")

      # Viewer should be redirected when accessing ctx2 (private workspace
      # they are NOT a member of).
      assert {:error, {:redirect, %{to: "/"}}} =
               Phoenix.LiveViewTest.live(conn, ~p"/#{ctx2.slug}/notes")
    end
  end
end
