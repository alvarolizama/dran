defmodule Dran.SharingTest do
  @moduledoc """
  Gate W2 (contract-instance-visibility-20260919): groups + shares +
  visibility columns behave.

  - groups: create/membership/unique slug
  - shares: user & group targets, idempotent, exactly-one-target CHECK
  - visibility: column exists on the 4 tables, new rows default `private`
  """

  use Dran.DataCase, async: true

  alias Dran.Accounts.UserGroup
  alias Dran.ContentShare
  alias Dran.{Collections, Knowledge, Repo, Reports, Sharing}

  setup do
    ws = ensure_workspace!()

    {:ok, owner} =
      Dran.Accounts.create_user(%{email: "sh-owner-#{uniq()}@example.com", api_token: "tok"})

    {:ok, reader} =
      Dran.Accounts.create_user(%{email: "sh-reader-#{uniq()}@example.com", api_token: "tok2"})

    {:ok, page} =
      Knowledge.create_page(%{
        workspace_id: ws.id,
        title: "Shareable #{uniq()}",
        page_type: "note"
      })

    {:ok, ws: ws, owner: owner, reader: reader, page: page}
  end

  describe "groups" do
    test "create derives the slug and membership is idempotent", %{reader: reader} do
      {:ok, group} = Sharing.create_group(%{name: "Equipo Producto"})
      assert group.slug == "equipo-producto"

      assert {:ok, _} = Sharing.add_group_member(group, reader.id)
      assert {:ok, _} = Sharing.add_group_member(group, reader.id)
      assert Sharing.group_ids_for(reader.id) == [group.id]
    end

    test "duplicate names get distinct slugs (slug is the identity)", ctx do
      assert {:ok, a} = Sharing.create_group(%{name: "Ops"})
      assert {:error, changeset} = Sharing.create_group(%{name: "Ops"})
      assert Enum.any?(changeset.errors, fn
               {:slug, {"has already been taken", _}} -> true
               _ -> false
             end)
      assert a.slug == "ops"
      assert ctx.page.slug
    end

    test "deleting a group cascades memberships", %{reader: reader} do
      {:ok, group} = Sharing.create_group(%{name: "Borrame"})
      {:ok, _} = Sharing.add_group_member(group, reader.id)
      Sharing.delete_group(group)

      assert Sharing.group_ids_for(reader.id) == []
    end
  end

  describe "shares" do
    test "share with user is idempotent and lists back", %{page: page, reader: reader} do
      assert {:ok, :shared} = Sharing.share_with_user("page", page.id, reader.id)
      assert {:ok, :shared} = Sharing.share_with_user("page", page.id, reader.id)

      [share] = Sharing.list_shares("page", page.id)
      assert share.user_id == reader.id
      assert share.user_group_id == nil
    end

    test "share with group grants every member", %{page: page, reader: reader, owner: owner} do
      {:ok, group} = Sharing.create_group(%{name: "Lectores #{uniq()}"})
      {:ok, _} = Sharing.add_group_member(group, reader.id)

      assert {:ok, :shared} = Sharing.share_with_group("page", page.id, group.id)
      assert Sharing.shared_with?("page", page.id, reader.id)
      refute Sharing.shared_with?("page", page.id, owner.id + 999_999)

      # unshare removes the grant
      [share] = Sharing.list_shares("page", page.id)
      :ok = Sharing.unshare(share.id)
      assert Sharing.list_shares("page", page.id) == []
      refute Sharing.shared_with?("page", page.id, reader.id)
    end

    test "a share must target exactly one of user/group (CHECK)", %{page: page} do
      {:error, changeset} =
        %ContentShare{}
        |> ContentShare.changeset(%{resource_type: "page", resource_id: page.id})
        |> Repo.insert()

      assert Enum.any?(changeset.errors, fn
               {:user_id, {"a share targets exactly one user or group", _}} -> true
               _ -> false
             end)
    end

    test "unknown resource_type is rejected", %{page: page, reader: reader} do
      {:error, changeset} =
        %ContentShare{}
        |> ContentShare.changeset(%{
          resource_type: "workspace",
          resource_id: page.id,
          user_id: reader.id
        })
        |> Repo.insert()

      assert Enum.any?(changeset.errors, fn
               {:resource_type, {"is invalid", _}} -> true
               _ -> false
             end)
    end
  end

  describe "visibility column" do
    test "new rows default private on every shareable table", ctx do
      assert ctx.page.visibility == "private"

      # Memory.add returns {:ok, memory, status} on creation.
      assert {:ok, memory, _status} =
               Dran.Memory.add(%{"content" => "facto #{uniq()}", "workspace_id" => ctx.ws.id})

      assert memory.visibility == "private"
    end

    test "collections and reports carry the column too", ctx do
      {:ok, collection} =
        Collections.create_collection(%{
          workspace_id: ctx.ws.id,
          name: "Col #{uniq()}",
          slug: "col-#{uniq()}",
          filters: %{}
        })

      assert collection.visibility == "private"

      {:ok, report} =
        Reports.create_report(%{
          workspace_id: ctx.ws.id,
          title: "Rep #{uniq()}",
          slug: "rep-#{uniq()}",
          report_type: "log"
        })

      assert report.visibility == "private"
    end
  end

  defp uniq, do: System.unique_integer([:positive])
end
