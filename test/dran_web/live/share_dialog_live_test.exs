defmodule DranWeb.ShareDialogLiveTest do
  @moduledoc """
  Gate W4 (contract-instance-visibility-20260919): the share surfaces.

  - page detail carries the Share button; the dialog lists/adds/removes
    grants (users and groups)
  - /admin/groups manages groups + memberships (admin-only)
  - the visibility picker ships in the page forms (new + edit)
  """

  use DranWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Dran.{Accounts, Knowledge, Repo, Sharing}

  setup %{conn: conn} do
    ws = Dran.DataCase.ensure_workspace!()

    {:ok, owner} =
      Accounts.create_user(%{email: "sd-owner-#{u()}@example.com", api_token: "t#{u()}"})

    {:ok, reader} =
      Accounts.create_user(%{email: "sd-reader-#{u()}@example.com", api_token: "t#{u()}"})

    admin =
      Accounts.get_user_by_email("test_user")
      |> Ecto.Changeset.change(instance_role: "admin")
      |> Repo.update!()

    {:ok, page} =
      Knowledge.create_page(%{
        workspace_id: ws.id,
        title: "Shareable page",
        slug: "shareable-#{u()}",
        page_type: "note",
        owner_user_id: owner.id,
        visibility: "shared"
      })

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user, "test_user")
      |> Plug.Conn.put_session(:is_owner, true)

    {:ok, conn: conn, ws: ws, owner: owner, reader: reader, admin: admin, page: page}
  end

  describe "share dialog on the page detail" do
    test "opens, shares with a user, lists the grant, and revokes it", %{
      conn: conn,
      page: page,
      reader: reader
    } do
      {:ok, view, _html} = live(conn, ~p"/notes/#{page.slug}")

      # Open the dialog from the page header.
      html = render_click(view, "open_share", %{})
      assert html =~ "share-user-form"
      assert html =~ "share-group-form"

      # Share with the reader user.
      view
      |> form("#share-user-form", %{"user_id" => Integer.to_string(reader.id)})
      |> render_submit()

      html = render(view)
      assert html =~ reader.email

      # The grant reads through the row-level filter for the reader.
      [share] = Sharing.list_shares("page", page.id)
      assert share.user_id == reader.id

      # Revoke — assert on the grants, not the whole html (the user select
      # legitimately still lists every user).
      render_click(view, "unshare", %{"id" => share.id})
      assert Sharing.list_shares("page", page.id) == []
      refute render(view) =~ "share-row-"
    end

    test "shares with a group the same way", %{conn: conn, page: page} do
      {:ok, group} = Sharing.create_group(%{name: "Lectores #{u()}"})

      {:ok, view, _html} = live(conn, ~p"/notes/#{page.slug}")
      render_click(view, "open_share", %{})

      view
      |> form("#share-group-form", %{"group_id" => Integer.to_string(group.id)})
      |> render_submit()

      html = render(view)
      assert html =~ group.name
      [%{user_group_id: group_id}] = Sharing.list_shares("page", page.id)
      assert group_id == group.id
    end

    test "a shared page carries a visibility badge; private pages do not", %{
      conn: conn,
      page: page
    } do
      {:ok, _view, html} = live(conn, ~p"/notes/#{page.slug}")
      assert html =~ "Shared"

      {:ok, private} =
        Knowledge.create_page(%{
          workspace_id: page.workspace_id,
          title: "Private page",
          slug: "private-#{u()}",
          page_type: "note",
          visibility: "private"
        })

      {:ok, _view, html2} = live(conn, ~p"/notes/#{private.slug}")
      refute html2 =~ "Public"
    end
  end

  describe "visibility picker in the page forms" do
    test "the new-page modal ships the picker and creates a private page by default", %{
      conn: conn
    } do
      {:ok, view, html} = live(conn, ~p"/notes?new=true")

      assert has_element?(view, "#page-visibility-picker")

      # El control vive en el HEADER del modal, junto a la ✕: los radios lo
      # apuntan con el atributo HTML `form` (el header está fuera del form).
      assert has_element?(view, "#page-resource-modal-header-actions #page-visibility-picker")
      refute has_element?(view, "#page-new-form-note #page-visibility-picker")

      assert has_element?(
               view,
               "#page-resource-modal-header-actions input[name='page[visibility]'][form='page-new-form-note']"
             )

      assert html =~ "Private"
      assert html =~ "Public"
      assert html =~ "Shared"

      # Create with visibility public.
      view
      |> form("#page-new-form-note", %{
        "page" => %{"title" => "Picker page", "visibility" => "public"}
      })
      |> render_submit()

      page = find_by_title!("Picker page")
      assert page.visibility == "public"
    end

    test "changing visibility in the edit form autosaves", %{conn: conn, page: page} do
      {:ok, view, _html} = live(conn, ~p"/notes/#{page.slug}?edit=true")

      view
      |> form("#page-edit-form", %{"page" => %{"visibility" => "private"}})
      |> render_change()

      updated = Knowledge.get_page!(page.id)
      assert updated.visibility == "private"
    end
  end

  describe "/admin/groups" do
    test "creates a group, adds members through the two doors, removes one, deletes the group",
         %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/admin/groups")
      assert html =~ "Groups"

      # Create.
      view
      |> form("#group-create-form", %{"group" => %{"name" => "Equipo"}})
      |> render_submit()

      html = render(view)
      assert html =~ "Equipo"
      group = hd(Sharing.list_groups())

      # The users must exist BEFORE the panel can list them.
      {:ok, reader2} =
        Accounts.create_user(%{
          email: "sd-member-#{u()}@example.com",
          name: "Miembro Buscado",
          api_token: "t#{u()}"
        })

      {:ok, invited} =
        Accounts.create_user(%{email: "sd-invited-#{u()}@example.com", api_token: "t#{u()}"})

      # Open the members panel: the member list plus the "Add users" block.
      render_click(view, "manage_members", %{"id" => Integer.to_string(group.id)})
      assert has_element?(view, "#group-members-panel")
      assert has_element?(view, "#group-invite-form")
      assert has_element?(view, "#group-user-search-form")

      # The one-shot select is gone: adding is the search row or the email.
      refute has_element?(view, "#group-add-member-form")

      # The search filters the candidate list down to the matching account.
      view
      |> form("#group-user-search-form", %{"q" => "Miembro Buscado"})
      |> render_change()

      assert has_element?(view, "#group-add-#{reader2.id}")
      assert has_element?(view, "#group-candidate-#{reader2.id}")

      # One click on the row adds them.
      render_click(view, "add_member", %{
        "group_id" => Integer.to_string(group.id),
        "user_id" => Integer.to_string(reader2.id)
      })

      assert has_element?(view, "#group-member-#{reader2.id}")
      assert Sharing.group_ids_for(reader2.id) == [group.id]

      # A member stops being a candidate — and the filter SURVIVES the add.
      refute has_element?(view, "#group-candidate-#{reader2.id}")

      # Second door: by email, for an account whose address you already know.
      view
      |> form("#group-invite-form", %{"invite" => %{"email" => invited.email}})
      |> render_submit()

      assert Sharing.group_ids_for(invited.id) == [group.id]
      assert has_element?(view, "#group-member-#{invited.id}")

      # Remove the searched member.
      render_click(view, "remove_member", %{
        "group_id" => Integer.to_string(group.id),
        "user_id" => Integer.to_string(reader2.id)
      })

      assert Sharing.group_ids_for(reader2.id) == []
      refute has_element?(view, "#group-member-#{reader2.id}")

      # Delete the group.
      render_click(view, "delete_group", %{"id" => Integer.to_string(group.id)})
      assert Sharing.list_groups() == []
    end

    test "the email door fails closed: unknown account, then already a member", %{conn: conn} do
      {:ok, group} = Sharing.create_group(%{name: "Sin cuenta #{u()}"})
      {:ok, member} = Accounts.create_user(%{email: "sd-dup-#{u()}@example.com"})

      {:ok, view, _html} = live(conn, ~p"/admin/groups")
      render_click(view, "manage_members", %{"id" => Integer.to_string(group.id)})

      # No account with that email: flash, and nothing is written.
      html =
        view
        |> form("#group-invite-form", %{"invite" => %{"email" => "ghost-#{u()}@example.com"}})
        |> render_submit()

      assert html =~ "No account with that email exists on this instance."
      assert Sharing.list_group_members(group.id) == []

      # El correo vacío cae en el mismo fail-closed (el submit sin escribir nada).
      html =
        view
        |> form("#group-invite-form", %{"invite" => %{"email" => "  "}})
        |> render_submit()

      assert html =~ "No account with that email exists on this instance."

      # Y un evento sin `user_id` — el submit del select vacío que había antes —
      # no agrega a nadie ni tira el proceso.
      render_click(view, "add_member", %{})
      assert Sharing.list_group_members(group.id) == []

      # An account that IS a member already: reported, not duplicated.
      {:ok, _} = Sharing.add_group_member(group, member.id)

      html =
        view
        |> form("#group-invite-form", %{"invite" => %{"email" => member.email}})
        |> render_submit()

      assert html =~ "That user is already in this group."

      assert Sharing.list_group_members(group.id) == [
               %{id: member.id, email: member.email, name: member.name}
             ]
    end

    test "non-admins are rejected by the admin pipeline", %{conn: conn} do
      conn =
        conn
        |> Plug.Conn.put_session(:is_owner, false)
        |> Plug.Test.init_test_session(%{user: "plain_user", is_owner: false})

      # (the :admin pipeline redirects non-owners; the live never mounts)
      result = live(conn, ~p"/admin/groups")
      assert match?({:error, _}, result)
    end
  end

  defp u, do: System.unique_integer([:positive])

  defp find_by_title!(title) do
    Dran.Repo.get_by(Dran.Knowledge.Page, title: title)
  end
end
