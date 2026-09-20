defmodule Dran.ContentVisibilityTest do
  @moduledoc """
  Gate W3 (contract-instance-visibility-20260919): the reader matrix.

  The instance is one workspace; isolation is per ITEM. A reader sees:

      own ∪ public ∪ shared-with-me (direct user share or via a group)

    reader            | own | other-private | public | shared-with-me | shared-ungranted
    ------------------|-----|---------------|--------|----------------|-----------------
    plain user        | yes | no            | yes    | yes            | no
    group member      | yes | no            | yes    | yes (via group)| no
    instance admin    | yes | yes           | yes    | yes            | yes
    api key (owner u) | exactly the owner's row
  """

  use Dran.DataCase, async: true

  import Ecto.Query
  alias Dran.{Accounts, ContentVisibility, Knowledge, Repo, Sharing}

  setup do
    ws = ensure_workspace!()

    {:ok, owner} =
      Accounts.create_user(%{email: "cv-owner-#{u()}@example.com", api_token: "t#{u()}"})

    {:ok, other} =
      Accounts.create_user(%{email: "cv-other-#{u()}@example.com", api_token: "t#{u()}"})

    {:ok, admin} =
      Accounts.create_user(%{email: "cv-admin-#{u()}@example.com", api_token: "t#{u()}"})

    admin = admin |> Ecto.Changeset.change(instance_role: "admin") |> Repo.update!()

    pages = %{
      own: create_page!(ws, owner, "own", "private"),
      other_private: create_page!(ws, other, "other-private", "private"),
      public: create_page!(ws, other, "public", "public"),
      shared_user: create_page!(ws, owner, "shared-user", "shared"),
      shared_other: create_page!(ws, other, "shared-other", "shared")
    }

    :ok = share_with_user!(pages.shared_user, other)

    {:ok, group} = Sharing.create_group(%{name: "CV Group #{u()}"})
    {:ok, _} = Sharing.add_group_member(group, other.id)
    group_page = create_page!(ws, owner, "shared-group", "shared")
    :ok = share_with_group!(group_page, group)
    pages = Map.put(pages, :shared_group, group_page)

    {:ok, ws: ws, owner: owner, other: other, admin: admin, pages: pages}
  end

  describe "scope resolution" do
    test "plain user reads as {:reader, id}", %{owner: owner} do
      expected = {:reader, owner.id}
      assert ^expected = ContentVisibility.scope(nil, owner, :pages)
    end

    test "instance admin and instance owner read as :all", ctx do
      assert :all = ContentVisibility.scope(nil, ctx.admin, :pages)

      owner_flag = Map.put(ctx.owner, :is_owner, true)
      assert :all = ContentVisibility.scope(nil, owner_flag, :pages)
    end

    test "API-key identity reads as its owner (Rules#3)", %{owner: owner} do
      expected = {:reader, owner.id}
      assert ^expected = ContentVisibility.scope(nil, %{owner_user_id: owner.id}, :pages)
    end

    test "nil and unknown identities keep the legacy :all posture" do
      assert :all = ContentVisibility.scope(nil, nil, :memory)
      assert :all = ContentVisibility.scope(nil, %{key_name: "legacy"}, :memory)
    end
  end

  describe "the reader matrix (pages)" do
    test "owner: own + public + own shared rows; NOT other's ungranted shared", ctx do
      # shared-other belongs to `other` and has no grant for owner — invisible
      # to them even though its visibility is "shared".
      assert visible_slugs(ctx.owner) == ~w(own public shared-group shared-user)
    end

    test "other user: own + public + shared-with-me (user AND group grants)", ctx do
      # other owns other-private AND shared-other (ungranted shared reads
      # private — but it is THEIRS, so still visible as own).
      assert visible_slugs(ctx.other) ==
               ~w(other-private public shared-group shared-other shared-user)
    end

    test "instance admin sees everything", ctx do
      # :all bypasses the filter — the admin's full view (alphabetical).
      assert query_slugs(:all) ==
               ~w(other-private own public shared-group shared-other shared-user)

      assert :all = ContentVisibility.scope(nil, ctx.admin, :pages)
    end

    test "api key reads exactly as its owner (query level)", %{other: other} do
      identity = %{owner_user_id: other.id}
      scope = ContentVisibility.resolve(nil, identity, :pages)
      expected = {:reader, other.id}
      assert ^expected = scope

      assert query_slugs(scope) ==
               ~w(other-private public shared-group shared-other shared-user)
    end

    test "visible?/3 agrees with filter/3 row by row", ctx do
      scope = {:reader, ctx.other.id}
      expected_for_other = ~w(other-private public shared-group shared-other shared-user)

      for {key, page} <- ctx.pages do
        assert ContentVisibility.visible?(page, scope, :page) ==
                 page.slug in expected_for_other,
               "row #{key} (#{page.slug}) disagrees with the matrix"
      end
    end

    test "unsharing revokes the read", ctx do
      [share] = Sharing.list_shares("page", ctx.pages.shared_user.id)
      :ok = Sharing.unshare(share.id)

      refute ctx.pages.shared_user.slug in visible_slugs(ctx.other)
      assert ctx.pages.shared_user.slug in visible_slugs(ctx.owner)
    end
  end

  describe "memories follow the same matrix" do
    test "private memory of another user is invisible; public is visible", ctx do
      # Memory.add returns {:ok, mem} or {:ok, mem, status} depending on the
      # dedupe path — accept both.
      {:ok, mine, _} =
        Dran.Memory.add(%{
          "content" => "fact mine #{u()}",
          "workspace_id" => ctx.ws.id,
          "owner_user_id" => ctx.other.id,
          "visibility" => "private"
        })
        |> then(fn
          {:ok, m} -> {:ok, m, :created}
          other -> other
        end)

      {:ok, pub, _} =
        Dran.Memory.add(%{
          "content" => "fact pub #{u()}",
          "workspace_id" => ctx.ws.id,
          "owner_user_id" => ctx.other.id,
          "visibility" => "public"
        })
        |> then(fn
          {:ok, m} -> {:ok, m, :created}
          other -> other
        end)

      slugs = memory_contents(ctx.owner)
      refute mine.content in slugs
      assert pub.content in slugs
    end
  end

  defp u, do: System.unique_integer([:positive])

  defp create_page!(ws, owner, slug, visibility) do
    {:ok, page} =
      Knowledge.create_page(%{
        workspace_id: ws.id,
        title: slug,
        slug: slug,
        page_type: "note",
        owner_user_id: owner.id,
        visibility: visibility
      })

    page
  end

  defp share_with_user!(page, user) do
    assert {:ok, :shared} = Sharing.share_with_user("page", page.id, user.id)
    :ok
  end

  defp share_with_group!(page, group) do
    assert {:ok, :shared} = Sharing.share_with_group("page", page.id, group.id)
    :ok
  end

  defp visible_slugs(user), do: query_slugs({:reader, user.id})

  defp query_slugs(scope) do
    from(p in Knowledge.Page, order_by: p.slug)
    |> ContentVisibility.filter(scope, :page)
    |> Repo.all()
    |> Enum.map(& &1.slug)
  end

  defp memory_contents(user) do
    from(m in Dran.Memory)
    |> ContentVisibility.filter({:reader, user.id}, :memory)
    |> Repo.all()
    |> Enum.map(& &1.content)
  end
end
