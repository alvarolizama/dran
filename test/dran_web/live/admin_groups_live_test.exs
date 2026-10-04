defmodule DranWeb.AdminGroupsLiveTest do
  @moduledoc """
  `/admin/groups` en el molde de la casa.

  La superficie tenía su propio molde: el alta era un formulario INLINE arriba
  de la página, el vacío un `<p>` sin `data-testid`, y `handle_event("rename_group")`
  existía SIN ningún control que lo alcanzara. Acá se ancla lo que la ola dejó:
  header compartido con el CTA que abre el modal por ESTADO DE URL (`?new=true`),
  alta y renombrado por el MISMO modal con `push_patch`, vacío del molde por
  contador, la fila con su puerta de edición y los payloads forjados que no
  revientan el proceso.
  """

  use DranWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Dran.Accounts
  alias Dran.Sharing

  defp owner_conn(conn) do
    email = "groups_owner@test.dev"

    case Accounts.get_user_by_email(email) do
      nil ->
        {:ok, _user} =
          Accounts.create_user(%{email: email, name: "Groups Owner", is_owner: true})

      _user ->
        :ok
    end

    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:user, email)
    |> Plug.Conn.put_session(:workspace_slug, "personal")
    |> Plug.Conn.put_session(:is_owner, true)
  end

  defp group_fixture(name) do
    {:ok, group} = Sharing.create_group(%{name: name})
    group
  end

  test "el header es el del molde y su CTA abre el alta por estado de URL",
       %{conn: conn} do
    conn = owner_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/admin/groups")

    assert has_element?(view, "[data-testid='new-group-button']", "New group")

    view |> element("[data-testid='new-group-button']") |> render_click()

    # El modal es ESTADO DE URL, no estado interno: la URL lo dice y el form
    # del alta vive en el cuerpo del shell (el botón Guardar está en el footer).
    assert_patch(view, ~p"/admin/groups?new=true")
    assert has_element?(view, "#group-resource-modal")
    assert has_element?(view, "#group-form input[name='group[name]']")
    assert has_element?(view, "#group-resource-modal button[form='group-form']")
  end

  test "el alta retirada: el formulario inline ya no existe", %{conn: conn} do
    conn = owner_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/admin/groups")

    refute has_element?(view, "#group-create-form")
  end

  test "crear un grupo pasa por el modal y la fila lo muestra",
       %{conn: conn} do
    conn = owner_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/admin/groups?new=true")

    view
    |> form("#group-form", %{"group" => %{"name" => "Equipo de diseño"}})
    |> render_submit()

    assert_patch(view, ~p"/admin/groups")
    refute has_element?(view, "#group-resource-modal")
    assert render(view) =~ "Group created."

    group = Enum.find(Sharing.list_groups(), &(&1.name == "Equipo de diseño"))
    assert group
    assert has_element?(view, "#group-row-#{group.id}", "Equipo de diseño")
    # El slug sigue siendo la identidad copiable de la fila.
    assert has_element?(view, "#group-slug-#{group.id}[data-slug='#{group.slug}']")
  end

  test "el vacío de la colección es el del molde y el CTA abre el alta",
       %{conn: conn} do
    conn = owner_conn(conn)

    for group <- Sharing.list_groups(), do: Sharing.delete_group(group)

    {:ok, view, _html} = live(conn, ~p"/admin/groups")

    assert has_element?(view, "[data-testid='empty-state']", "No groups yet")
    assert has_element?(view, "[data-testid='empty-state'] a[href='/admin/groups?new=true']")
  end

  test "renombrar un grupo es alcanzable desde la fila y guarda",
       %{conn: conn} do
    conn = owner_conn(conn)
    group = group_fixture("Nombre viejo")

    {:ok, view, _html} = live(conn, ~p"/admin/groups")
    assert has_element?(view, "#group-row-#{group.id}", "Nombre viejo")

    view |> element("#group-edit-#{group.id}") |> render_click()

    assert_patch(view, ~p"/admin/groups?edit=#{group.id}")
    assert has_element?(view, "#group-resource-modal", "Rename group")
    # El modal abre con el nombre puesto y el id del grupo viajando en el form.
    assert has_element?(
             view,
             "#group-form input[name='group[name]'][value='Nombre viejo']"
           )

    assert has_element?(view, "#group-form input[name='_id'][value='#{group.id}']")

    view
    |> form("#group-form", %{"group" => %{"name" => "Nombre nuevo"}})
    |> render_submit()

    assert_patch(view, ~p"/admin/groups")
    refute has_element?(view, "#group-resource-modal")
    assert render(view) =~ "Group renamed."
    assert Sharing.get_group!(group.id).name == "Nombre nuevo"
    assert has_element?(view, "#group-row-#{group.id}", "Nombre nuevo")
  end

  test "cerrar el modal vuelve a la URL limpia", %{conn: conn} do
    conn = owner_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/admin/groups?new=true")

    assert has_element?(view, "#group-resource-modal")

    view |> element("#group-resource-modal button[aria-label='Close']") |> render_click()

    assert_patch(view, ~p"/admin/groups")
    refute has_element?(view, "#group-resource-modal")
  end

  test "un ?edit desconocido no abre ningún modal", %{conn: conn} do
    conn = owner_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/admin/groups?edit=999999")

    refute has_element?(view, "#group-resource-modal")
  end

  test "payloads forjados no revientan el proceso ni escriben",
       %{conn: conn} do
    conn = owner_conn(conn)
    group = group_fixture("Intacto")

    {:ok, view, _html} = live(conn, ~p"/admin/groups")

    # Alta sin nombre y renombrado con un id que no existe: no hacen nada.
    render_click(view, "save_group", %{})
    render_click(view, "rename_group", %{"_id" => "999999", "group" => %{"name" => "x"}})

    # Membresías con ids forjados, incluidos los no numéricos (el `String.to_integer/1`
    # del molde viejo reventaba con un ArgumentError).
    render_click(view, "add_member", %{"group_id" => "999999", "user_id" => "1"})
    render_click(view, "add_member", %{"group_id" => "forged", "user_id" => "x"})
    render_click(view, "remove_member", %{"group_id" => "forged", "user_id" => "x"})
    render_click(view, "delete_group", %{"id" => "forged"})

    assert Sharing.get_group!(group.id).name == "Intacto"
    assert has_element?(view, "#group-row-#{group.id}")
  end

  test "el panel de miembros sigue abriendo en la página", %{conn: conn} do
    conn = owner_conn(conn)
    group = group_fixture("Con miembros")

    {:ok, user} =
      Accounts.create_user(%{email: "groups_member@test.dev", name: "Grupo Miembro"})

    {:ok, _} = Accounts.create_user(%{email: "groups_other@test.dev", name: "Otro"})

    {:ok, view, _html} = live(conn, ~p"/admin/groups")

    view |> element("#group-members-#{group.id}") |> render_click()

    assert has_element?(view, "#group-members-panel")
    assert has_element?(view, "#group-members-panel", "Con miembros")

    view
    |> form("#group-invite-form", %{"invite" => %{"email" => user.email}})
    |> render_submit()

    assert has_element?(view, "#group-member-#{user.id}", user.email)

    view
    |> element("#group-member-#{user.id} button[title='Remove from group']")
    |> render_click()

    refute has_element?(view, "#group-member-#{user.id}")
  end
end
