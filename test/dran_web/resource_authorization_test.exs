defmodule DranWeb.ResourceAuthorizationTest do
  @moduledoc """
  Permission matrix for the single authorization policy
  (`DranWeb.ResourceAuthorization`).

  Identity shapes × workspace reachability × mode. The shapes mirror what
  `DranWeb.Router.require_api_token/2` and `DranWeb.API.MCPController`
  actually produce.
  """

  use Dran.DataCase, async: false

  alias Dran.{Accounts, Knowledge}
  alias DranWeb.ResourceAuthorization, as: Authz

  setup do
    {:ok, ws} = Knowledge.create_workspace(%{name: "Authz", slug: "authz-ws"})

    {:ok, ws: ws}
  end

  describe "nil user (process_message tests / no auth)" do
    test "allowed read and write anywhere (legacy fail-open)" do
      assert Authz.authorize(nil, :read, "authz-ws") == :ok
      assert Authz.authorize(nil, :write, "authz-ws") == :ok
    end
  end

  describe "legacy admin token shape (contexts: :all)" do
    test "allowed read and write anywhere" do
      user = %{is_owner: true, email: "admin", contexts: :all}

      assert Authz.authorize(user, :read, "authz-ws") == :ok
      assert Authz.authorize(user, :write, "authz-ws") == :ok
    end
  end

  describe "MCP legacy admin shape (workspaces: :all)" do
    test "allowed read and write anywhere" do
      user = %{is_owner: true, email: "admin", workspaces: :all}

      assert Authz.authorize(user, :read, "authz-ws") == :ok
      assert Authz.authorize(user, :write, "authz-ws") == :ok
    end
  end

  describe "per-user token (%Accounts.User{})" do
    test "instance owner: read + write everywhere" do
      {:ok, user} = Accounts.create_user(%{email: uniq_email(), is_owner: true})

      assert Authz.authorize(user, :read, "authz-ws") == :ok
      assert Authz.authorize(user, :write, "authz-ws") == :ok
    end

    test "member with owner role: read + write" do
      {:ok, user} = Accounts.create_user(%{email: uniq_email()})
      {:ok, ws} = Knowledge.create_workspace(%{name: "Owned", slug: "authz-owned"})

      {:ok, _} = Accounts.add_user_to_workspace(user, ws)
      {:ok, _} = Accounts.update_member_role(user, ws, "owner")

      assert Authz.authorize(user, :read, ws.id) == :ok
      assert Authz.authorize(user, :write, ws.id) == :ok
    end

    test "member with editor role: read + write" do
      {:ok, user} = Accounts.create_user(%{email: uniq_email()})

      {:ok, _} = Accounts.add_user_to_workspace(user, ws_from_setup())
      {:ok, _} = Accounts.update_member_role(user, ws_from_setup(), "editor")

      assert Authz.authorize(user, :read, ws_from_setup().id) == :ok
      assert Authz.authorize(user, :write, ws_from_setup().id) == :ok
    end

    test "member with viewer role: read allowed, write denied" do
      {:ok, user} = Accounts.create_user(%{email: uniq_email()})
      {:ok, _} = Accounts.add_user_to_workspace(user, ws_from_setup())

      assert Authz.authorize(user, :read, ws_from_setup().id) == :ok
      assert {:error, :forbidden} = Authz.authorize(user, :write, ws_from_setup().id)
    end

    test "public non-member: read allowed (viewer fallback), write denied" do
      {:ok, user} = Accounts.create_user(%{email: uniq_email()})

      # setup workspace is public by default
      assert Authz.authorize(user, :read, ws_from_setup().id) == :ok
      assert {:error, :forbidden} = Authz.authorize(user, :write, ws_from_setup().id)
    end

    test "private workspace non-member: read and write denied" do
      {:ok, private} =
        Knowledge.create_workspace(%{
          name: "Private",
          slug: "authz-private",
          visibility: "private"
        })

      {:ok, user} = Accounts.create_user(%{email: uniq_email()})

      assert {:error, :forbidden} = Authz.authorize(user, :read, private.id)
      assert {:error, :forbidden} = Authz.authorize(user, :write, private.id)
    end
  end

  describe "API key shape (access_levels)" do
    test "read-only key: read ok, write forbidden" do
      ws = ws_from_setup()

      user = %{
        is_owner: false,
        email: "api-key:reader",
        key_name: "Reader",
        workspaces: [ws],
        access_levels: %{ws.id => "read"},
        created_by_user_id: nil
      }

      assert Authz.authorize(user, :read, ws.id) == :ok
      assert {:error, :forbidden} = Authz.authorize(user, :write, ws.id)
    end

    test "write-enabled key: read + write ok" do
      ws = ws_from_setup()

      user = %{
        is_owner: false,
        email: "api-key:writer",
        key_name: "Writer",
        workspaces: [ws],
        access_levels: %{ws.id => "write"},
        created_by_user_id: nil
      }

      assert Authz.authorize(user, :read, ws.id) == :ok
      assert Authz.authorize(user, :write, ws.id) == :ok
    end

    test "key with no entry for the workspace is forbidden" do
      user = %{
        is_owner: false,
        email: "api-key:elsewhere",
        key_name: "Elsewhere",
        workspaces: [],
        access_levels: %{"some-other-ws-id" => "write"},
        created_by_user_id: nil
      }

      assert {:error, :forbidden} = Authz.authorize(user, :read, ws_from_setup().id)
      assert {:error, :forbidden} = Authz.authorize(user, :write, ws_from_setup().id)
    end
  end

  describe "unknown workspace" do
    test "authenticated user without access: forbidden" do
      {:ok, user} = Accounts.create_user(%{email: uniq_email()})

      assert {:error, :forbidden} = Authz.authorize(user, :read, "no-such-ws")
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp ws_from_setup, do: Knowledge.get_workspace_by_slug("authz-ws")

  defp uniq_email, do: "user-#{System.unique_integer([:positive])}@test.local"
end
