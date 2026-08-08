defmodule Dran.AccountsTest do
  # async: false — this suite checks out a sandbox connection. Async DB
  # tests race with sync tests running in shared mode (DBConnection
  # OwnershipError / "client exited"), so all Repo-using suites are sync.
  use Dran.DataCase, async: false

  alias Dran.Accounts
  alias Dran.Accounts.User
  alias Dran.Brain

  @user_attrs %{email: "alice@example.com", name: "Alice", avatar_url: "http://example.com/a.png"}

  describe "User CRUD" do
    test "create_user/1 inserts a user with an auto-generated api_token" do
      assert {:ok, user} = Accounts.create_user(@user_attrs)
      assert user.email == "alice@example.com"
      assert user.name == "Alice"
      assert user.is_admin == false
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
      {:ok, _} = Accounts.add_user_to_context(user, context)

      found = Accounts.get_user_by_email(user.email)
      assert found.id == user.id
      assert [_ctx] = found.contexts
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
      {:ok, _} = Accounts.add_user_to_context(user, context)

      assert [found] = Accounts.list_users()
      assert found.id == user.id
      assert [_ctx] = found.contexts
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

    test "add_user_to_context/2 associates a user with a context", %{user: user, context: context} do
      assert {:ok, uc} = Accounts.add_user_to_context(user, context)
      assert uc.user_id == user.id
      assert uc.context_id == context.id
      assert Accounts.user_in_context?(user, context)
    end

    test "add_user_to_context/2 enforces uniqueness", %{user: user, context: context} do
      assert {:ok, _} = Accounts.add_user_to_context(user, context)
      assert {:error, changeset} = Accounts.add_user_to_context(user, context)

      assert {"has already been taken", _} =
               changeset.errors |> Enum.map(& &1) |> List.first() |> elem(1)
    end

    test "user_in_context?/2 returns true for a member", %{user: user, context: context} do
      refute Accounts.user_in_context?(user, context)
      {:ok, _} = Accounts.add_user_to_context(user, context)
      assert Accounts.user_in_context?(user, context)
    end

    test "remove_user_from_context/2 detaches a user", %{user: user, context: context} do
      {:ok, _} = Accounts.add_user_to_context(user, context)
      assert Accounts.user_in_context?(user, context)

      assert {1, _} = Accounts.remove_user_from_context(user, context)
      refute Accounts.user_in_context?(user, context)
      assert {0, _} = Accounts.remove_user_from_context(user, context)
    end

    test "list_user_contexts/1 returns the user's assigned contexts", %{
      user: user,
      context: context
    } do
      other = context_fixture(%{name: "Work", slug: "work"})
      {:ok, _} = Accounts.add_user_to_context(user, context)
      {:ok, _} = Accounts.add_user_to_context(user, other)

      ids = Accounts.list_user_contexts(user) |> Enum.map(& &1.id)
      assert Enum.sort(ids) == Enum.sort([context.id, other.id])
    end
  end

  describe "admin" do
    test "admin_user/0 returns the admin user" do
      assert {:ok, _} = Accounts.create_user(@user_attrs)

      admin_attrs =
        @user_attrs |> Map.put(:email, "admin@example.com") |> Map.put(:is_admin, true)

      assert {:ok, admin} = Accounts.create_user(admin_attrs)

      assert Accounts.admin_user().id == admin.id
    end

    test "admin_user/0 returns nil when no admin exists" do
      assert {:ok, _} = Accounts.create_user(@user_attrs)
      assert Accounts.admin_user() == nil
    end

    test "is_admin?/1 returns true only for admins" do
      {:ok, user} = Accounts.create_user(@user_attrs)

      admin_attrs =
        @user_attrs |> Map.put(:email, "admin@example.com") |> Map.put(:is_admin, true)

      {:ok, admin} = Accounts.create_user(admin_attrs)
      assert Accounts.is_admin?(admin)
      refute Accounts.is_admin?(user)
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
      {:ok, _} = Accounts.add_user_to_context(user, ctx1)
      {:ok, _} = Accounts.add_user_to_context(user, ctx2)

      assert {:ok, authed} = Accounts.valid_token?(user.api_token)

      assert Enum.map(authed.contexts, & &1.id) |> Enum.sort() ==
               Enum.sort([ctx1.id, ctx2.id])
    end
  end

  # Helpers

  defp context_fixture(attrs \\ %{}) do
    unique = System.unique_integer([:positive])
    attrs = Map.put_new(attrs, :name, "Context #{unique}")
    attrs = Map.put_new(attrs, :slug, "ctx-#{unique}")
    {:ok, context} = Brain.create_context(attrs)
    context
  end
end
