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

      # Every account is created with its own personal workspace, so the
      # memberships on the struct are that one plus the context added here.
      assert Enum.sort(Enum.map(found.workspaces, & &1.id)) ==
               Enum.sort([user.personal_workspace_id, context.id])
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

      assert Enum.sort(Enum.map(found.workspaces, & &1.id)) ==
               Enum.sort([user.personal_workspace_id, context.id])
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

      assert Enum.sort(ids) ==
               Enum.sort([user.personal_workspace_id, context.id, other.id])
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
               Enum.sort([user.personal_workspace_id, ctx1.id, ctx2.id])
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

    test "replace_api_key_workspaces/3 swaps the matrix preserving the token", %{
      user: user,
      ctx1: ctx1,
      ctx2: ctx2
    } do
      {:ok, _} = Accounts.add_user_to_workspace(user, ctx2)

      {:ok, key} =
        Accounts.create_api_key(%{
          name: "replace-test",
          workspace_ids: [{ctx1.id, "read"}],
          created_by_user_id: user.id
        })

      assert {:ok, updated} =
               Accounts.replace_api_key_workspaces(
                 key,
                 [{ctx1.id, "write"}, {ctx2.id, "read"}],
                 user
               )

      levels = Map.new(updated.api_key_workspaces, &{&1.workspace_id, &1.access_level})
      assert levels[ctx1.id] == "write"
      assert levels[ctx2.id] == "read"

      # the credential survives the matrix edit
      assert {:ok, _} = Accounts.valid_api_key?(key.token)
    end

    test "replace_api_key_workspaces/3 rejects workspaces outside the creator's membership", %{
      non_member: non_member,
      ctx2: ctx2
    } do
      {:ok, key} =
        Accounts.create_api_key(%{
          name: "replace-forbidden",
          workspace_ids: [],
          created_by_user_id: non_member.id
        })

      assert {:error, :workspace_not_allowed} =
               Accounts.replace_api_key_workspaces(key, [{ctx2.id, "read"}], non_member)
    end
  end

  describe "session_workspace_slug/1 — where a logged-in session lands" do
    test "an unknown user resolves to the instance default" do
      assert Accounts.session_workspace_slug(nil) == Dran.Auth.default_workspace_slug()
    end

    test "the owner lands on their personal workspace, ahead of the flagged default" do
      unique = System.unique_integer([:positive])

      {:ok, owner} =
        Accounts.create_user(%{
          email: "landing-owner-#{unique}@example.com",
          name: "Owner",
          is_owner: true
        })

      {:ok, flagged} =
        Knowledge.create_workspace(%{name: "Flagged #{unique}", slug: "landing-flag-#{unique}"})

      {:ok, _} = Knowledge.update_workspace(flagged, %{is_default: true})

      # Creating the account created its personal workspace, and that is where
      # the owner lands: the instance-wide flagged default no longer decides.
      personal = Accounts.personal_workspace(owner)
      assert personal
      assert owner.default_workspace_slug == personal.slug
      assert Accounts.session_workspace_slug(owner) == personal.slug
      refute Accounts.session_workspace_slug(owner) == flagged.slug
    end

    test "the owner's own default wins while the workspace still exists" do
      unique = System.unique_integer([:positive])

      {:ok, owner} =
        Accounts.create_user(%{
          email: "landing-owner2-#{unique}@example.com",
          name: "Owner",
          is_owner: true
        })

      {:ok, mine} =
        Knowledge.create_workspace(%{name: "Mine #{unique}", slug: "landing-mine-#{unique}"})

      {:ok, _} = Accounts.set_default_context(owner, mine.slug)

      {:ok, flagged} =
        Knowledge.create_workspace(%{name: "Flagged #{unique}", slug: "landing-flag2-#{unique}"})

      {:ok, _} = Knowledge.update_workspace(flagged, %{is_default: true})

      reloaded = Accounts.get_user_by_email(owner.email)
      assert Accounts.session_workspace_slug(reloaded) == mine.slug
    end

    test "a stale personal default is dropped" do
      unique = System.unique_integer([:positive])

      {:ok, user} =
        Accounts.create_user(%{email: "landing-stale-#{unique}@example.com", name: "Stale"})

      {:ok, _} = Accounts.set_default_context(user, "workspace-que-ya-no-existe")

      # Rule 1 needs a live workspace: the dead slug is dropped, and the
      # personal workspace answers next instead of the instance default.
      reloaded = Accounts.get_user_by_email(user.email)

      assert Dran.Auth.default_workspace_slug() == "personal"

      assert Accounts.session_workspace_slug(reloaded) ==
               Accounts.personal_workspace(reloaded).slug

      refute Accounts.session_workspace_slug(reloaded) == "personal"
    end

    test "a workspace you are not a member of is not reachable, flagged or not" do
      unique = System.unique_integer([:positive])

      {:ok, user} =
        Accounts.create_user(%{email: "landing-public-#{unique}@example.com", name: "Public"})

      {:ok, flagged} =
        Knowledge.create_workspace(%{name: "Flagged #{unique}", slug: "landing-flag3-#{unique}"})

      {:ok, _} = Knowledge.update_workspace(flagged, %{is_default: true})

      reloaded = Accounts.get_user_by_email(user.email)

      # Every workspace is private: being the instance default grants nobody
      # access, so the flagged workspace is not even in this user's list — and
      # the personal workspace keeps being the landing place.
      refute Accounts.accessible_workspaces(reloaded)
             |> Enum.map(& &1.slug)
             |> Enum.member?(flagged.slug)

      assert Accounts.session_workspace_slug(reloaded) ==
               Accounts.personal_workspace(reloaded).slug
    end

    @tag :no_default_workspace
    test "a personal workspace wins even with several workspaces reachable" do
      unique = System.unique_integer([:positive])

      {:ok, user} =
        Accounts.create_user(%{email: "landing-many-#{unique}@example.com", name: "Many"})

      {:ok, one} =
        Knowledge.create_workspace(%{
          name: "One #{unique}",
          slug: "landing-one-#{unique}"
        })

      {:ok, two} =
        Knowledge.create_workspace(%{
          name: "Two #{unique}",
          slug: "landing-two-#{unique}"
        })

      {:ok, _} = Accounts.add_user_to_workspace(user, one)
      {:ok, _} = Accounts.add_user_to_workspace(user, two)

      reloaded = Accounts.get_user_by_email(user.email)

      # The personal workspace is the landing place even with the other two
      # reachable: reachability is not the same thing as being where you start.
      assert Accounts.accessible_workspaces(reloaded) |> Enum.map(& &1.slug) |> Enum.sort() ==
               Enum.sort([Accounts.personal_workspace(reloaded).slug, one.slug, two.slug])

      assert Accounts.session_workspace_slug(reloaded) ==
               Accounts.personal_workspace(reloaded).slug
    end

    @tag :no_default_workspace
    test "without a personal workspace, a user reaching exactly ONE lands there" do
      unique = System.unique_integer([:positive])

      {:ok, user} =
        Accounts.create_user(%{email: "landing-single-#{unique}@example.com", name: "Single"})

      # Both workspaces are private and only `mine` is a membership: the one
      # workspace the account actually reaches must win over the instance
      # default it cannot open.
      {:ok, mine} =
        Knowledge.create_workspace(%{
          name: "Mine #{unique}",
          slug: "landing-solo-#{unique}"
        })

      {:ok, _other} =
        Knowledge.create_workspace(%{
          name: "Other #{unique}",
          slug: "landing-other-#{unique}"
        })

      # Simulate a pre-personal-workspaces account: the personal membership AND
      # the pointer are gone, so `mine` really is the only workspace it reaches.
      {1, _} = Accounts.remove_user_from_workspace(user, Accounts.personal_workspace(user))
      {:ok, _} = Accounts.add_user_to_workspace(user, mine)
      {:ok, _} = Accounts.update_user(user, %{default_workspace_slug: nil})

      # The account's own personal workspace was the first workspace created
      # here, so the bootstrap rule flagged it as the instance default; that
      # default is unreachable for this account now (membership only), which is
      # exactly why the only-reachable rule has to answer.
      reloaded = Accounts.get_user_by_email(user.email)
      bare = %{reloaded | personal_workspace_id: nil}
      assert Dran.Auth.default_workspace_slug() != mine.slug
      assert Accounts.session_workspace_slug(bare) == mine.slug
    end
  end

  describe "personal workspaces" do
    test "every account is created with its own private personal workspace" do
      assert {:ok, user} = Accounts.create_user(@user_attrs)

      assert user.personal_workspace_id
      personal = Accounts.personal_workspace(user)
      assert personal
      assert personal.visibility == "private"
      refute personal.is_default

      # Linked as an owner membership too, so every existing access check works.
      assert Accounts.user_in_workspace?(user, personal)
      assert Accounts.user_role_in_workspace(user, personal) == "owner"
    end

    test "the personal workspace seeds the landing slug but never clobbers an explicit choice" do
      assert {:ok, user} = Accounts.create_user(@user_attrs)
      personal = Accounts.personal_workspace(user)
      assert user.default_workspace_slug == personal.slug

      other = context_fixture()
      {:ok, _} = Accounts.set_default_context(user, other.slug)

      assert {:ok, _} =
               Accounts.ensure_personal_workspace(Accounts.get_user_by_email(user.email))

      assert Accounts.get_user_by_email(user.email).default_workspace_slug == other.slug
    end

    @tag :no_default_workspace
    test "ensure_personal_workspace/1 is idempotent" do
      assert {:ok, user} = Accounts.create_user(@user_attrs)
      personal = Accounts.personal_workspace(user)

      assert {:ok, ensured} =
               Accounts.ensure_personal_workspace(Accounts.get_user_by_email(user.email))

      assert ensured.id == personal.id
      # W1: every personal workspace points at the single instance workspace,
      # and the test DB ships it — count relative, not absolute.
      assert Repo.aggregate(Dran.Workspace, :count, :id) >= 1
    end

    test "a stale struct cannot create a second personal workspace" do
      assert {:ok, user} = Accounts.create_user(@user_attrs)
      personal = Accounts.personal_workspace(user)
      before = Repo.aggregate(Dran.Workspace, :count, :id)

      # Exactly what the losing half of a race looks like: our copy of the
      # account still says "no personal workspace" while the row already has one.
      # The function trusts the locked row, not the struct it was handed, so the
      # loser creates nothing instead of leaving an orphan in the user's list.
      stale = %{user | personal_workspace_id: nil}

      assert {:ok, ensured} = Accounts.ensure_personal_workspace(stale)
      assert ensured.id == personal.id
      assert Repo.aggregate(Dran.Workspace, :count, :id) == before
    end

    test "the database refuses to hand one workspace to two accounts" do
      assert {:ok, a} = Accounts.create_user(%{email: "pa@example.com", name: "PA"})
      assert {:ok, b} = Accounts.create_user(%{email: "pb@example.com", name: "PB"})

      # `ensure_personal_workspace/1` holds the application half of the
      # invariant (the row lock); this is the schema half, and it is real: no
      # raw write can point two accounts at the same personal workspace.
      assert_raise Ecto.ConstraintError, fn ->
        b
        |> Ecto.Changeset.change(personal_workspace_id: a.personal_workspace_id)
        |> Repo.update()
      end
    end

    test "two accounts sharing a display name get distinct personal workspaces" do
      assert {:ok, a} = Accounts.create_user(%{email: "same-a@example.com", name: "Same"})
      assert {:ok, b} = Accounts.create_user(%{email: "same-b@example.com", name: "Same"})

      pa = Accounts.personal_workspace(a)
      pb = Accounts.personal_workspace(b)

      assert pa.id != pb.id
      # The NAME is allowed to repeat — it is a label. What cannot repeat is the
      # slug, because it is the URL identity, so the second one is suffixed.
      assert pa.name == pb.name
      assert pa.slug != pb.slug
    end

    test "backfill_personal_workspaces/0 covers accounts that lack one" do
      assert {:ok, user} = Accounts.create_user(@user_attrs)

      # Shaped like a pre-personal-workspaces account: no membership and no
      # pointer (deleting the workspace NILIFIES users.personal_workspace_id).
      personal = Accounts.personal_workspace(user)
      {1, _} = Accounts.remove_user_from_workspace(user, personal)
      {:ok, _} = Dran.Knowledge.delete_workspace(personal)

      assert Accounts.get_user_by_email(user.email).personal_workspace_id == nil
      assert Accounts.backfill_personal_workspaces() == {1, 0}
      assert Accounts.personal_workspace(Accounts.get_user_by_email(user.email))
      assert Accounts.backfill_personal_workspaces() == {0, 0}
    end

    test "accessible_workspaces/1 lists the personal workspace first" do
      assert {:ok, user} = Accounts.create_user(@user_attrs)
      other = context_fixture()
      {:ok, _} = Accounts.add_user_to_workspace(user, other)

      assert [first | _] = Accounts.accessible_workspaces(Accounts.get_user_by_email(user.email))
      assert first.id == user.personal_workspace_id
    end

    test "a workspace is reachable only by its members" do
      assert {:ok, member} = Accounts.create_user(%{email: "member@example.com", name: "Member"})
      assert {:ok, outsider} = Accounts.create_user(%{email: "outside@example.com", name: "Out"})

      {:ok, ws} = Knowledge.create_workspace(%{name: "Compartida", slug: "compartida"})
      {:ok, _} = Accounts.add_user_to_workspace(member, ws)

      reachable = fn user ->
        Accounts.get_user_by_email(user.email)
        |> Accounts.accessible_workspaces()
        |> Enum.map(& &1.id)
      end

      assert ws.id in reachable.(member)
      # Every workspace is private: there is no public tier that would put it in
      # a stranger's list.
      refute ws.id in reachable.(outsider)
      assert ws.visibility == "private"
    end
  end

  describe "create_workspace_for/2 (creation permission)" do
    test "is denied by default" do
      assert {:ok, user} = Accounts.create_user(@user_attrs)
      refute Accounts.can_create_workspaces?(user)

      assert {:error, :forbidden} =
               Accounts.create_workspace_for(user, %{name: "Hers", slug: "hers"})

      refute Dran.Knowledge.get_workspace_by_slug("hers")
    end

    test "a granted user creates one and becomes its owner member" do
      assert {:ok, user} = Accounts.create_user(@user_attrs)
      assert {:ok, granted} = Accounts.update_user(user, %{can_create_workspaces: true})
      assert Accounts.can_create_workspaces?(granted)

      assert {:ok, ws} = Accounts.create_workspace_for(granted, %{name: "Hers", slug: "hers"})
      assert ws.slug == "hers"
      assert Accounts.user_in_workspace?(granted, ws)
      assert Accounts.user_role_in_workspace(granted, ws) == "owner"
    end

    test "the instance owner always may" do
      assert {:ok, owner} = Accounts.create_user(Map.put(@user_attrs, :is_owner, true))
      assert Accounts.can_create_workspaces?(owner)
      assert {:ok, _ws} = Accounts.create_workspace_for(owner, %{name: "Ours", slug: "ours"})
    end

    test "a failed workspace insert leaves no membership behind (same transaction)" do
      assert {:ok, user} = Accounts.create_user(@user_attrs)
      assert {:ok, granted} = Accounts.update_user(user, %{can_create_workspaces: true})

      # The SLUG is what is unique ("personal" is the fixture's), so the insert
      # fails there — and the owner membership must not be written either. A
      # repeated NAME would no longer fail at all.
      assert {:error, %Ecto.Changeset{}} =
               Accounts.create_workspace_for(granted, %{name: "Otra", slug: "personal"})

      assert length(Accounts.list_user_workspaces(granted)) == 1
    end

    test "a repeated name is fine, the slug is what gets suffixed" do
      assert {:ok, user} = Accounts.create_user(@user_attrs)
      assert {:ok, granted} = Accounts.update_user(user, %{can_create_workspaces: true})

      # Same display name as the "Personal" fixture: allowed. The slug is
      # derived from the name and suffix on collision.
      assert {:ok, twin} = Accounts.create_workspace_for(granted, %{name: "Personal"})

      assert twin.name == "Personal"
      assert twin.slug != "personal"
      assert Dran.Knowledge.get_workspace_by_slug(twin.slug).id == twin.id
      assert Accounts.user_role_in_workspace(granted, twin) == "owner"
    end

    test "refuses a name the creator already has in their list" do
      assert {:ok, user} = Accounts.create_user(%{email: "dupe@example.com", name: "Dupe"})
      assert {:ok, granted} = Accounts.update_user(user, %{can_create_workspaces: true})

      personal = Accounts.personal_workspace(granted)

      # Their personal workspace is in their list, so its name is taken — and the
      # point is that they get told, instead of silently receiving /dupe-3f9a2b.
      assert {:error, :name_taken} =
               Accounts.create_workspace_for(granted, %{name: personal.name})

      # Case and surrounding blanks do not buy a second one.
      assert {:error, :name_taken} =
               Accounts.create_workspace_for(granted, %{
                 name: "  #{String.upcase(personal.name)}  "
               })

      # Nor does it create anything on the way out.
      assert Enum.count(Dran.Knowledge.list_workspaces(), &(&1.name == personal.name)) == 1
    end

    test "another account may still use the same name" do
      assert {:ok, alice} = Accounts.create_user(%{email: "alice@example.com", name: "Alice"})
      assert {:ok, bob} = Accounts.create_user(%{email: "bob@example.com", name: "Bob"})
      assert {:ok, alice} = Accounts.update_user(alice, %{can_create_workspaces: true})
      assert {:ok, bob} = Accounts.update_user(bob, %{can_create_workspaces: true})

      # The check is scoped to the creator's own list. Two people can both run a
      # "Trabajo", and the database does not stand in the way: names are labels.
      assert {:ok, a_ws} = Accounts.create_workspace_for(alice, %{name: "Trabajo"})
      assert {:ok, b_ws} = Accounts.create_workspace_for(bob, %{name: "Trabajo"})

      assert a_ws.name == b_ws.name
      assert a_ws.slug != b_ws.slug
      refute Accounts.user_in_workspace?(bob, a_ws)
    end
  end

  describe "add_member_by_email/3 (inviting an existing account)" do
    test "adds an existing account with the given role" do
      ws = context_fixture()
      assert {:ok, member} = Accounts.create_user(%{email: "member@example.com", name: "Member"})

      assert {:ok, %Dran.Accounts.UserWorkspace{}} =
               Accounts.add_member_by_email(ws, "member@example.com", "editor")

      assert Accounts.user_in_workspace?(member, ws)
      assert Accounts.user_role_in_workspace(member, ws) == "editor"
    end

    test "is case-insensitive and trims the submitted email" do
      ws = context_fixture()
      assert {:ok, _member} = Accounts.create_user(%{email: "Mixed@Example.com", name: "Mixed"})

      assert {:ok, _} = Accounts.add_member_by_email(ws, "  mIXED@example.COM  ", "viewer")
    end

    test "refuses an email with no account — Dran has no invitation emails" do
      ws = context_fixture()
      assert {:error, :user_not_found} = Accounts.add_member_by_email(ws, "ghost@example.com")
      assert {:error, :user_not_found} = Accounts.add_member_by_email(ws, "")
    end

    test "reports an existing membership instead of a raw constraint error" do
      ws = context_fixture()
      assert {:ok, _member} = Accounts.create_user(%{email: "dup@example.com", name: "Dup"})

      assert {:ok, _} = Accounts.add_member_by_email(ws, "dup@example.com")
      assert {:error, :already_member} = Accounts.add_member_by_email(ws, "dup@example.com")
    end
  end

  describe "credenciales y vínculo de identidad de una cuenta nueva" do
    test "create_user_with_password/1 deja la contraseña con la que la persona entra" do
      assert {:ok, user} =
               Accounts.create_user_with_password(%{
                 email: "invitado@example.com",
                 name: "Invitado",
                 password: "contrasena-larga-123"
               })

      assert is_binary(user.password_hash)
      assert {:ok, _} = Accounts.authenticate_user("invitado@example.com", "contrasena-larga-123")
      assert {:error, :unauthorized} = Accounts.authenticate_user("invitado@example.com", "otra")
    end

    test "exige contraseña: sin ella devuelve el error, no una cuenta sin entrada" do
      assert {:error, changeset} =
               Accounts.create_user_with_password(%{
                 email: "sin-clave@example.com",
                 name: "Sin Clave"
               })

      assert "can't be blank" in errors_on(changeset).password
      refute Accounts.get_user_by_email("sin-clave@example.com")
    end

    test "acepta los params del formulario tal cual, con claves string" do
      # Los params de una LiveView llegan con claves string y el changeset tiene
      # que llevarlos así para que Phoenix pinte los errores en el campo
      # (`used_input?` busca la clave string dentro de form.params).
      assert {:ok, user} =
               Accounts.create_user_with_password(%{
                 "email" => "params@example.com",
                 "name" => "Params",
                 "password" => "contrasena-larga-123"
               })

      assert is_binary(user.api_token)
      assert {:ok, _} = Accounts.authenticate_user("params@example.com", "contrasena-larga-123")
    end

    test "create_user/1 no da credenciales: es el camino de Google/API, no el de una persona" do
      assert {:ok, user} = Accounts.create_user(%{email: "sin-credenciales@example.com"})

      assert is_nil(user.password_hash)

      assert {:error, :unauthorized} =
               Accounts.authenticate_user("sin-credenciales@example.com", "lo-que-sea")
    end

    test "la cuenta queda enlazada a su actor de identidad" do
      # `Map.put(attrs, :actor_id, ...)` no bastaba: `User.changeset/2` no castea
      # :actor_id, así que el valor se perdía en silencio — la fila en `actors`
      # se creaba y users.actor_id quedaba NULL, con lo que el guard de
      # `Dran.Actors.delete_actor/1` sobre la identidad de un usuario nunca se
      # activaba.
      assert {:ok, user} = Accounts.create_user(%{email: "vinculo@example.com"})

      assert user.actor_id
      assert Dran.Actors.get_actor_by_name("vinculo@example.com").id == user.actor_id
    end
  end

  describe "el nombre manda: el workspace personal no nace del correo" do
    test "lleva el nombre de la persona y su slug sale de ahí, no del correo" do
      {:ok, user} =
        Accounts.create_user_with_password(%{
          email: "alvaro@local.dev",
          name: "Álvaro Lizama",
          password: "contrasena-larga-123"
        })

      workspace = Accounts.personal_workspace(user)
      assert workspace.name == "Álvaro Lizama"
      assert workspace.slug == "alvaro-lizama"
      refute workspace.slug =~ "local"
      refute workspace.name =~ "@"
    end

    test "sin nombre es \"Personal\": el correo no aparece en nombre ni slug" do
      {:ok, user} = Accounts.create_user(%{email: "nekrox@gmail.com"})

      workspace = Accounts.personal_workspace(user)
      assert workspace.name == "Personal"
      refute workspace.slug =~ "nekrox"
      refute workspace.slug =~ "gmail"
    end

    test "registrar sin nombre no crea la cuenta" do
      assert {:error, changeset} =
               Accounts.create_user_with_password(%{
                 email: "sin-nombre@example.com",
                 password: "contrasena-larga-123"
               })

      assert "can't be blank" in errors_on(changeset).name
      refute Accounts.get_user_by_email("sin-nombre@example.com")
    end
  end

  describe "reset de contraseña desde /admin/users" do
    test "da entrada a una cuenta que no la tenía, sin pedir la contraseña anterior" do
      assert {:ok, user} = Accounts.create_user(%{email: "rescatada@example.com"})
      assert is_nil(user.password_hash)

      assert {:ok, updated} =
               Accounts.update_user_as_admin(user, %{
                 "email" => "rescatada@example.com",
                 "name" => "Rescatada",
                 "password" => "nueva-larga-123"
               })

      assert updated.name == "Rescatada"
      assert {:ok, _} = Accounts.authenticate_user("rescatada@example.com", "nueva-larga-123")
    end

    test "en blanco no la toca — ni la deja con el hash de la cadena vacía" do
      {:ok, user} =
        Accounts.create_user_with_password(%{
          email: "intacta@example.com",
          name: "Intacta",
          password: "original-larga-123"
        })

      assert {:ok, updated} =
               Accounts.update_user_as_admin(user, %{"name" => "Otro", "password" => ""})

      assert updated.name == "Otro"
      assert updated.password_hash == user.password_hash
      assert {:ok, _} = Accounts.authenticate_user("intacta@example.com", "original-larga-123")
    end

    test "una contraseña corta devuelve el error y no guarda ni el nombre" do
      {:ok, user} =
        Accounts.create_user_with_password(%{
          email: "corta@example.com",
          name: "Corta",
          password: "original-larga-123"
        })

      assert {:error, changeset} =
               Accounts.update_user_as_admin(user, %{"name" => "Corto", "password" => "corta"})

      assert "should be at least 8 character(s)" in errors_on(changeset).password

      reloaded = Accounts.get_user!(user.id)
      assert reloaded.name == user.name
      assert reloaded.password_hash == user.password_hash
    end
  end
end
