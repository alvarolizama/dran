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

  describe "legacy admin shape (workspaces: :all)" do
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

    # ── W5: the instance role decides (single-workspace) ────────────────────

    test "instance viewer: read allowed, write denied" do
      {:ok, user} = Accounts.create_user(%{email: uniq_email()})
      user = user |> Ecto.Changeset.change(instance_role: "viewer") |> Dran.Repo.update!()

      assert Authz.authorize(user, :read, "authz-ws") == :ok
      assert {:error, :forbidden} = Authz.authorize(user, :write, "authz-ws")
    end

    test "instance editor: read + write" do
      {:ok, user} = Accounts.create_user(%{email: uniq_email()})
      user = user |> Ecto.Changeset.change(instance_role: "editor") |> Dran.Repo.update!()

      assert Authz.authorize(user, :read, "authz-ws") == :ok
      assert Authz.authorize(user, :write, "authz-ws") == :ok
    end

    test "default role (editor): write allowed on any workspace id" do
      {:ok, user} = Accounts.create_user(%{email: uniq_email()})

      assert Authz.authorize(user, :read, "authz-ws") == :ok
      assert Authz.authorize(user, :write, "authz-ws") == :ok
    end
  end

  describe "account identity map (la credencial única de la cuenta)" do
    # La forma que `DranWeb.Router.require_api_token/2` asigna al `api_token`
    # de la cuenta (W3): un mapa, no el struct, porque la identidad del agente
    # (`agent_name` del header) se resuelve ahí y en ningún otro lado.
    test "editor: read + write" do
      ws = ws_from_setup()
      user = account_identity(instance_role: "editor")

      assert Authz.authorize(user, :read, ws.id) == :ok
      assert Authz.authorize(user, :write, ws.id) == :ok
    end

    test "viewer: read ok, write forbidden" do
      ws = ws_from_setup()
      user = account_identity(instance_role: "viewer")

      assert Authz.authorize(user, :read, ws.id) == :ok
      assert {:error, :forbidden} = Authz.authorize(user, :write, ws.id)
    end

    test "dueño de la instancia: read + write aunque su rol de instancia sea editor" do
      ws = ws_from_setup()
      user = account_identity(is_owner: true, instance_role: "editor")

      assert Authz.authorize(user, :read, ws.id) == :ok
      assert Authz.authorize(user, :write, ws.id) == :ok
    end

    test "mapa autenticado sin rol de instancia: prohibido (fail-closed)" do
      ws = ws_from_setup()

      assert {:error, :forbidden} = Authz.authorize(%{email: "agent@dran.test"}, :read, ws.id)
      assert {:error, :forbidden} = Authz.authorize(%{email: "agent@dran.test"}, :write, ws.id)
    end
  end

  describe "unknown workspace" do
    test "authenticated user is authorized regardless of the ws id (W5)" do
      {:ok, user} = Accounts.create_user(%{email: uniq_email()})

      assert :ok = Authz.authorize(user, :read, "no-such-ws")
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp ws_from_setup, do: Knowledge.get_workspace_by_slug("authz-ws")

  defp uniq_email, do: "user-#{System.unique_integer([:positive])}@test.local"

  # The exact shape the API auth pipeline assigns for an account token (W3).
  defp account_identity(overrides) do
    Map.merge(
      %{
        id: 1,
        email: "agent@dran.test",
        is_owner: false,
        instance_role: "editor",
        agent_name: "hermes",
        created_by_user_id: 1,
        owner_user_id: 1,
        actor: %{id: "account:1", name: "hermes", display_name: nil}
      },
      Map.new(overrides)
    )
  end
end
