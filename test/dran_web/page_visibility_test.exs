defmodule DranWeb.PageVisibilityTest do
  @moduledoc """
  Gate del modelo personal (W-P1): lo que se crea desde la web es DE SU AUTOR y
  nazca privado se lee solo por su autor — no por cualquiera con el slug.

  Antes de esta fase la escritura web no sellaba `owner_user_id` (NULL) y el
  detalle no aplicaba scope: el autor no veía su propia página en la lista y
  cualquiera con la URL la abría. Aquí se fijan las dos mitades.
  """
  use DranWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Dran.{Accounts, Knowledge, Sharing}

  defp editor!(label) do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.create_user(%{
        email: "#{label}-#{unique}@dran.test",
        api_token: "tok-#{label}-#{unique}"
      })

    user
  end

  # A non-owner member: `instance_role` defaults to "editor", which reads as
  # `{:reader, id}` — the ordinary personal reader.
  defp login(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:user, user.email)
    |> Plug.Conn.put_session(:is_owner, false)
    |> Plug.Conn.put_session(:workspace_slug, "personal")
  end

  defp create_page_via_ui(conn, title) do
    {:ok, view, _html} = live(conn, ~p"/notes?new=true")

    view
    |> form("#page-new-form-note", %{page: %{"title" => title}})
    |> render_submit()
  end

  test "nace privada y con dueño, y su autor la ve en la lista y en el detalle" do
    author = editor!("author")
    ws = Dran.DataCase.ensure_workspace!()
    conn = login(build_conn(), author)

    create_page_via_ui(conn, "Mi nota personal")

    page = Knowledge.get_page_by_slug("mi-nota-personal", ws.id)
    assert page, "la página debería existir"
    assert page.visibility == "private"
    assert page.owner_user_id == author.id

    {:ok, list, _html} = live(conn, ~p"/notes")
    assert has_element?(list, "[data-testid='page-card-mi-nota-personal']")

    assert {:ok, _detail, html} = live(conn, ~p"/notes/mi-nota-personal")
    assert html =~ "Mi nota personal"
  end

  test "otro usuario no la ve en la lista NI abriéndola por URL" do
    author = editor!("owner2")
    stranger = editor!("stranger")
    _ws = Dran.DataCase.ensure_workspace!()

    create_page_via_ui(login(build_conn(), author), "Secreto del autor")

    conn = login(build_conn(), stranger)

    {:ok, list, _html} = live(conn, ~p"/notes")
    refute has_element?(list, "[data-testid='page-card-secreto-del-autor']")

    assert {:error, {:live_redirect, %{to: to}}} =
             live(conn, ~p"/notes/secreto-del-autor")

    assert to == "/notes"
  end

  test "el dueño de la instancia conserva la vista completa" do
    author = editor!("owner3")
    _ws = Dran.DataCase.ensure_workspace!()

    create_page_via_ui(login(build_conn(), author), "Nota ajena al owner")

    owner_conn =
      build_conn()
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user, "test_user")
      |> Plug.Conn.put_session(:is_owner, true)
      |> Plug.Conn.put_session(:workspace_slug, "personal")

    {:ok, _list, _html} = live(owner_conn, ~p"/notes")
    assert {:ok, _detail, html} = live(owner_conn, ~p"/notes/nota-ajena-al-owner")
    assert html =~ "Nota ajena al owner"
  end

  test "pública: cualquier usuario la ve (guard)" do
    author = editor!("pub")
    reader = editor!("pubreader")
    ws = Dran.DataCase.ensure_workspace!()

    create_page_via_ui(login(build_conn(), author), "Nota publica")

    page = Knowledge.get_page_by_slug("nota-publica", ws.id)
    {:ok, _} = Knowledge.update_page(page, %{visibility: "public"})

    conn = login(build_conn(), reader)
    {:ok, list, _html} = live(conn, ~p"/notes")
    assert has_element?(list, "[data-testid='page-card-nota-publica']")
    assert {:ok, _detail, _html} = live(conn, ~p"/notes/nota-publica")
  end

  test "compartida con una persona: solo esa la ve (guard)" do
    author = editor!("share")
    invited = editor!("invited")
    outsider = editor!("outsider")
    ws = Dran.DataCase.ensure_workspace!()

    create_page_via_ui(login(build_conn(), author), "Nota compartida")

    page = Knowledge.get_page_by_slug("nota-compartida", ws.id)
    {:ok, _} = Knowledge.update_page(page, %{visibility: "shared"})
    {:ok, :shared} = Sharing.share_with_user("page", page.id, invited.id)

    {:ok, invited_list, _} = live(login(build_conn(), invited), ~p"/notes")
    assert has_element?(invited_list, "[data-testid='page-card-nota-compartida']")
    assert {:ok, _d, _h} = live(login(build_conn(), invited), ~p"/notes/nota-compartida")

    {:ok, outsider_list, _} = live(login(build_conn(), outsider), ~p"/notes")
    refute has_element?(outsider_list, "[data-testid='page-card-nota-compartida']")

    assert {:error, {:live_redirect, _}} =
             live(login(build_conn(), outsider), ~p"/notes/nota-compartida")
  end
end
