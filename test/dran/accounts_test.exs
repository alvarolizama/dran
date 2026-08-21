defmodule Dran.AccountsTest do
  # async: false — this suite checks out a sandbox connection. Async DB
  # tests race with sync tests running in shared mode (DBConnection
  # OwnershipError / "client exited"), so all Repo-using suites are sync.
  use Dran.DataCase, async: false

  alias Dran.Accounts
  alias Dran.Accounts.User
  alias Dran.Knowledge

  @user_attrs %{email: "alice@example.com", name: "Alice", avatar_url: "http://example.com/a.png"}

  describe "User CRUD" do
    test "create_user/1 inserts a user with an auto-generated api_token" do
      assert {:ok, user} = Accounts.create_user(@user_attrs)
      assert user.email == "alice@example.com"
      assert user.name == "Alice"
      assert user.is_owner == false
      assert is_binary(user.api_token)
      assert String.length(user.api_token) > 20
    end

    test "create_user/1 generates a unique api_token per user" do
      assert {:ok, user1} =
               Accounts.create_user(%{@user_attrs | email: "bob1@example.com"})

      assert {:ok, user2} =
               Accounts.create_user(%{@user_attrs | email: "bob2@example.com"})

      refute user1.api_token == user2.api_token
    end

    test "create_user/1 returns errors for invalid attrs" do
      assert {:error, changeset} = Accounts.create_user(%{email: nil})
      assert "can't be blank" in errors_on(changeset).email
    end

    test "get_user_by_email/1 returns the preloaded user" do
      assert {:ok, user} = Accounts.create_user(@user_attrs)
      context = context_fixture()
      {:ok, _} = Accounts.add_user_to_workspace(user, context)

      found = Accounts.get_user_by_email(user.email)
      assert found.id == user.id
      assert [_ctx] = found.workspaces
    end

    test "get_user_by_email/1 returns nil when not found" do
      assert Accounts.get_user_by_email("nobody@example.com") == nil
    end

    test "get_user_by_google_id/1 finds a user by google id" do
      user_attrs = Map.put(@user_attrs, :google_id, "g-123")
      assert {:ok, user} = Accounts.create_user(user_attrs)
      assert Accounts.get_user_by_google_id("g-123").id == user.id
      assert Accounts.get_user_by_google_id("g-missing") == nil
    end

    test "get_user_by_api_token/1 finds a user by token" do
      assert {:ok, user} = Accounts.create_user(@user_attrs)
      assert Accounts.get_user_by_api_token(user.api_token).id == user.id
      assert Accounts.get_user_by_api_token("bogus-token") == nil
    end

    test "regenerate_api_token/1 replaces the token and invalidates the old one" do
      assert {:ok, user} = Accounts.create_user(@user_attrs)
      old_token = user.api_token

      assert {:ok, %User{api_token: new_token}} = Accounts.regenerate_api_token(user)
      assert is_binary(new_token)
      assert String.length(new_token) > 20
      refute new_token == old_token

      assert Accounts.get_user_by_api_token(old_token) == nil
      assert Accounts.get_user_by_api_token(new_token).id == user.id
    end

    test "get_user!/1 and get_user/1 fetch by id" do
      assert {:ok, user} = Accounts.create_user(@user_attrs)
      assert Accounts.get_user!(user.id).id == user.id
      assert Accounts.get_user(user.id).id == user.id
      assert Accounts.get_user(-1) == nil
    end

    test "list_users/0 returns all users with preloaded contexts" do
      assert {:ok, user} = Accounts.create_user(@user_attrs)
      context = context_fixture()
      {:ok, _} = Accounts.add_user_to_workspace(user, context)

      assert [found] = Accounts.list_users()
      assert found.id == user.id
      assert [_ctx] = found.workspaces
    end

    test "update_user/2 updates a user" do
      assert {:ok, user} = Accounts.create_user(@user_attrs)
      assert {:ok, updated} = Accounts.update_user(user, %{name: "Alice B"})
      assert updated.name == "Alice B"
      # api_token must not change on a normal update
      assert updated.api_token == user.api_token
    end

    test "delete_user/1 removes a user" do
      assert {:ok, user} = Accounts.create_user(@user_attrs)
      assert {:ok, _} = Accounts.delete_user(user)
      assert Accounts.get_user(user.id) == nil
    end
  end

  describe "find_or_link_from_google/1" do
    test "rejects a user that does not exist and does not create one" do
      assert {:error, :unauthorized} =
               Accounts.find_or_link_from_google(%{
                 email: "new@example.com",
                 google_id: "g-new",
                 name: "Newbie",
                 avatar_url: "http://example.com/new.png"
               })

      assert Repo.aggregate(User, :count, :id) == 0
      assert Accounts.get_user_by_email("new@example.com") == nil
    end

    test "returns existing user when google_id already matches" do
      user_attrs = Map.put(@user_attrs, :google_id, "g-dup")
      assert {:ok, user} = Accounts.create_user(user_attrs)

      assert {:ok, found} =
               Accounts.find_or_link_from_google(%{
                 email: "alice@example.com",
                 google_id: "g-dup",
                 name: "Renamed"
               })

      assert found.id == user.id
      assert found.google_id == "g-dup"
      assert Accounts.get_user_by_email("alice@example.com").id == user.id
    end

    test "links google_id to an existing user found by email" do
      assert {:ok, user} =
               Accounts.create_user(%{
                 email: "link@example.com",
                 name: "No Google Yet"
               })

      assert user.google_id == nil

      assert {:ok, linked} =
               Accounts.find_or_link_from_google(%{
                 email: "link@example.com",
                 google_id: "g-link",
                 name: "Now Linked",
                 avatar_url: "http://example.com/l.png"
               }),
             "existing email user should be updated"

      assert linked.id == user.id
      assert linked.google_id == "g-link"
      assert linked.name == "Now Linked"
      assert linked.avatar_url == "http://example.com/l.png"
      # still same account, one row
      assert Accounts.get_user_by_email("link@example.com").id == user.id
    end

    test "does not create a second account when linking via email" do
      assert {:ok, _} = Accounts.create_user(%{email: "one@example.com"})

      assert {:ok, user} =
               Accounts.find_or_link_from_google(%{email: "one@example.com", google_id: "g-1"})

      assert Repo.aggregate(User, :count, :id) == 1
      assert user.email == "one@example.com"
    end
  end

  describe "context membership" do
    setup do
      {:ok, user} = Accounts.create_user(@user_attrs)
      context = context_fixture()
      %{user: user, context: context}
    end

    test "add_user_to_workspace/2 associates a user with a context", %{
      user: user,
      context: context
    } do
      assert {:ok, uc} = Accounts.add_user_to_workspace(user, context)
      assert uc.user_id == user.id
      assert uc.workspace_id == context.id
      assert Accounts.user_in_workspace?(user, context)
    end

    test "add_user_to_workspace/2 enforces uniqueness", %{user: user, context: context} do
      assert {:ok, _} = Accounts.add_user_to_workspace(user, context)
      assert {:error, changeset} = Accounts.add_user_to_workspace(user, context)

      assert {"has already been taken", _} =
               changeset.errors |> Enum.map(& &1) |> List.first() |> elem(1)
    end

    test "user_in_workspace?/2 returns true for a member", %{user: user, context: context} do
      refute Accounts.user_in_workspace?(user, context)
      {:ok, _} = Accounts.add_user_to_workspace(user, context)
      assert Accounts.user_in_workspace?(user, context)
    end

    test "remove_user_from_workspace/2 detaches a user", %{user: user, context: context} do
      {:ok, _} = Accounts.add_user_to_workspace(user, context)
      assert Accounts.user_in_workspace?(user, context)

      assert {1, _} = Accounts.remove_user_from_workspace(user, context)
      refute Accounts.user_in_workspace?(user, context)
      assert {0, _} = Accounts.remove_user_from_workspace(user, context)
    end

    test "list_user_workspaces/1 returns the user's assigned contexts", %{
      user: user,
      context: context
    } do
      other = context_fixture(%{name: "Work", slug: "work"})
      {:ok, _} = Accounts.add_user_to_workspace(user, context)
      {:ok, _} = Accounts.add_user_to_workspace(user, other)

      ids = Accounts.list_user_workspaces(user) |> Enum.map(& &1.id)
      assert Enum.sort(ids) == Enum.sort([context.id, other.id])
    end
  end

  describe "owner" do
    test "owner_user/0 returns the owner user" do
      assert {:ok, _} = Accounts.create_user(@user_attrs)

      owner_attrs =
        @user_attrs |> Map.put(:email, "owner@example.com") |> Map.put(:is_owner, true)

      assert {:ok, owner} = Accounts.create_user(owner_attrs)

      assert Accounts.owner_user().id == owner.id
    end

    test "owner_user/0 returns nil when no owner exists" do
      assert {:ok, _} = Accounts.create_user(@user_attrs)
      assert Accounts.owner_user() == nil
    end

    test "is_owner?/1 returns true only for owners" do
      {:ok, user} = Accounts.create_user(@user_attrs)

      owner_attrs =
        @user_attrs |> Map.put(:email, "owner@example.com") |> Map.put(:is_owner, true)

      {:ok, owner} = Accounts.create_user(owner_attrs)
      assert Accounts.is_owner?(owner)
      refute Accounts.is_owner?(user)
    end
  end

  describe "valid_token?/1" do
    test "returns {:ok, user} for a valid admin/normal token" do
      {:ok, user} = Accounts.create_user(@user_attrs)
      assert {:ok, found} = Accounts.valid_token?(user.api_token)
      assert found.id == user.id
    end

    test "returns :error for an unknown token" do
      assert Accounts.valid_token?("totally-bogus") == :error
    end

    test "user token grants access to all assigned contexts (preloaded)" do
      {:ok, user} = Accounts.create_user(@user_attrs)
      ctx1 = context_fixture(%{name: "A", slug: "a"})
      ctx2 = context_fixture(%{name: "B", slug: "b"})
      {:ok, _} = Accounts.add_user_to_workspace(user, ctx1)
      {:ok, _} = Accounts.add_user_to_workspace(user, ctx2)

      assert {:ok, authed} = Accounts.valid_token?(user.api_token)

      assert Enum.map(authed.workspaces, & &1.id) |> Enum.sort() ==
               Enum.sort([ctx1.id, ctx2.id])
    end
  end

  # Helpers

  defp context_fixture(attrs \\ %{}) do
    unique = System.unique_integer([:positive])
    attrs = Map.put_new(attrs, :name, "Context #{unique}")
    attrs = Map.put_new(attrs, :slug, "ctx-#{unique}")
    {:ok, context} = Knowledge.create_workspace(attrs)
    context
  end

  describe "API Key scoping" do
    setup do
      {:ok, owner} =
        Accounts.create_user(
          Map.put(@user_attrs, :email, "owner-scoping@example.com")
          |> Map.put(:is_owner, true)
        )

      {:ok, user} =
        Accounts.create_user(Map.put(@user_attrs, :email, "user-scoping@example.com"))

      {:ok, non_member} =
        Accounts.create_user(Map.put(@user_attrs, :email, "non-member@example.com"))

      ctx1 = context_fixture(%{name: "Scoped1", slug: "scoped1"})
      ctx2 = context_fixture(%{name: "Scoped2", slug: "scoped2"})

      {:ok, _} = Accounts.add_user_to_workspace(user, ctx1)

      %{owner: owner, user: user, non_member: non_member, ctx1: ctx1, ctx2: ctx2}
    end

    test "list_api_keys/1 returns all keys for owner", %{
      owner: owner,
      user: user,
      ctx1: ctx1
    } do
      {:ok, key1} =
        Accounts.create_api_key(%{
          name: "key1",
          workspace_ids: [{ctx1.id, "read"}],
          created_by_user_id: user.id
        })

      {:ok, key2} =
        Accounts.create_api_key(%{
          name: "key2",
          workspace_ids: [{ctx1.id, "read"}],
          created_by_user_id: owner.id
        })

      keys = Accounts.list_api_keys(owner)
      ids = Enum.map(keys, & &1.id)
      assert key1.id in ids
      assert key2.id in ids
    end

    test "list_api_keys/1 returns only own keys for non-owner", %{
      user: user,
      owner: owner,
      ctx1: ctx1
    } do
      {:ok, key1} =
        Accounts.create_api_key(%{
          name: "key1",
          workspace_ids: [{ctx1.id, "read"}],
          created_by_user_id: user.id
        })

      {:ok, _key2} =
        Accounts.create_api_key(%{
          name: "key2",
          workspace_ids: [{ctx1.id, "read"}],
          created_by_user_id: owner.id
        })

      keys = Accounts.list_api_keys(user)
      ids = Enum.map(keys, & &1.id)
      assert key1.id in ids
      # Should only have key1
      refute Enum.any?(ids, &(&1 != key1.id))
    end

    test "create_api_key/1 allows owner to create key for any workspace", %{
      owner: owner,
      ctx2: ctx2
    } do
      assert {:ok, _key} =
               Accounts.create_api_key(%{
                 name: "owner-key",
                 workspace_ids: [{ctx2.id, "read"}],
                 created_by_user_id: owner.id
               })
    end

    test "create_api_key/1 allows member to create key for their workspace", %{
      user: user,
      ctx1: ctx1
    } do
      assert {:ok, _key} =
               Accounts.create_api_key(%{
                 name: "user-key",
                 workspace_ids: [{ctx1.id, "read"}],
                 created_by_user_id: user.id
               })
    end

    test "create_api_key/1 disallows non-member from creating key for unassigned workspace", %{
      non_member: non_member,
      ctx2: ctx2
    } do
      assert {:error, :workspace_not_allowed} =
               Accounts.create_api_key(%{
                 name: "non-member-key",
                 workspace_ids: [{ctx2.id, "read"}],
                 created_by_user_id: non_member.id
               })
    end

    test "update_api_key_access/3 updates access level", %{
      user: user,
      ctx1: ctx1
    } do
      {:ok, key} =
        Accounts.create_api_key(%{
          name: "update-test",
          workspace_ids: [{ctx1.id, "read"}],
          created_by_user_id: user.id
        })

      key = Dran.Repo.preload(key, api_key_workspaces: :workspace)
      akw = hd(key.api_key_workspaces)
      assert akw.access_level == "read"

      assert {:ok, updated_akw} = Accounts.update_api_key_access(key, ctx1.id, "write")
      assert updated_akw.access_level == "write"
    end

    test "update_api_key_access/3 returns error for invalid access level", %{
      user: user,
      ctx1: ctx1
    } do
      {:ok, key} =
        Accounts.create_api_key(%{
          name: "update-test-invalid",
          workspace_ids: [{ctx1.id, "read"}],
          created_by_user_id: user.id
        })

      assert {:error, :invalid_access_level} =
               Accounts.update_api_key_access(key, ctx1.id, "invalid")
    end

    test "update_api_key_access/3 returns error for workspace not in key", %{
      user: user,
      ctx1: ctx1,
      ctx2: ctx2
    } do
      {:ok, key} =
        Accounts.create_api_key(%{
          name: "update-test-missing",
          workspace_ids: [{ctx1.id, "read"}],
          created_by_user_id: user.id
        })

      assert {:error, :workspace_not_found_for_key} =
               Accounts.update_api_key_access(key, ctx2.id, "write")
    end
  end
end
