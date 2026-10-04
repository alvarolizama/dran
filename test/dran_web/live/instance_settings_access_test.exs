defmodule DranWeb.InstanceSettingsAccessTest do
  @moduledoc """
  `/settings/instance` es administración de la instancia: entra el dueño o un
  `instance_role` admin/owner. Un usuario normal NO la lee — la guardia vive en
  la ruta (`pipeline :instance_admin`) y su gemelo en el socket
  (`LiveAuth.on_mount(:require_instance_admin, ...)`), no en la página.

  La matriz se prueba por los DOS caminos: la petición HTTP + el mount del
  LiveView (`live/2` corre los plugs y el `on_mount`) y el hook suelto, que es
  el que cubre el re-mount por websocket.
  """

  use DranWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Dran.Accounts
  alias Dran.Repo

  defp user!(email, attrs \\ %{}) do
    {:ok, user} = Accounts.create_user(Map.merge(%{email: email, name: email}, attrs))
    user
  end

  defp with_role(user, role) do
    user |> Ecto.Changeset.change(instance_role: role) |> Repo.update!()
  end

  defp session_conn(conn, email, is_owner) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:user, email)
    |> Plug.Conn.put_session(:workspace_slug, "personal")
    |> Plug.Conn.put_session(:is_owner, is_owner)
  end

  describe "la ruta (/settings/instance)" do
    test "el dueño de la instancia entra", %{conn: conn} do
      owner = user!("instance_owner@test.dev", %{is_owner: true})
      conn = session_conn(conn, owner.email, true)

      {:ok, _view, html} = live(conn, ~p"/settings/instance")

      assert html =~ "Instance settings"
    end

    test "un admin de instancia entra (sin ser el dueño)", %{conn: conn} do
      admin = user!("instance_admin@test.dev") |> with_role("admin")
      conn = session_conn(conn, admin.email, false)

      {:ok, _view, html} = live(conn, ~p"/settings/instance")

      assert html =~ "Instance settings"
    end

    test "un usuario normal (viewer) NO entra: vuelve al home", %{conn: conn} do
      viewer = user!("instance_viewer@test.dev") |> with_role("viewer")
      conn = session_conn(conn, viewer.email, false)

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/settings/instance")
    end

    test "un editor tampoco: no es rol de administración", %{conn: conn} do
      editor = user!("instance_editor@test.dev") |> with_role("editor")
      conn = session_conn(conn, editor.email, false)

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/settings/instance")
    end

    test "una sesión sin usuario va al login", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/settings/instance")
    end

    test "una sesión con usuario borrado (sin fila) no entra", %{conn: conn} do
      conn = session_conn(conn, "deleted@test.dev", true)

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/settings/instance")
    end
  end

  describe "el nav muestra Instance settings donde el guard ya admitiría" do
    # El guard de la ruta admite owner ∪ admin de instancia EN CUALQUIER página;
    # el ítem del nav no puede depender de dónde esté parado el lector: la misma
    # fila que decide el guard decide el enlace (bug medido: en /settings/account
    # un admin de instancia perdía el enlace porque `can_config` salía del rol
    # de membresía del workspace, que para él era nil).
    test "un admin de instancia ve el enlace en /settings/account", %{conn: conn} do
      admin = user!("nav_admin@test.dev") |> with_role("admin")
      conn = session_conn(conn, admin.email, false)

      {:ok, view, _html} = live(conn, ~p"/settings/account")

      assert has_element?(view, "aside a[href='/settings/instance']")
    end

    test "un admin de instancia ve el enlace también en una página de conocimiento", %{
      conn: conn
    } do
      admin = user!("nav_admin_knowledge@test.dev") |> with_role("admin")
      conn = session_conn(conn, admin.email, false)

      {:ok, view, _html} = live(conn, ~p"/notes")

      assert has_element?(view, "#user-menu a[href='/settings/instance']")
    end

    test "un viewer no lo ve en ninguna de las dos", %{conn: conn} do
      viewer = user!("nav_viewer@test.dev") |> with_role("viewer")
      conn = session_conn(conn, viewer.email, false)

      {:ok, view_account, _html} = live(conn, ~p"/settings/account")
      {:ok, view_notes, _html} = live(conn, ~p"/notes")

      refute has_element?(view_account, "aside a[href='/settings/instance']")
      refute has_element?(view_notes, "#user-menu a[href='/settings/instance']")
    end
  end

  describe "el gemelo del socket (re-mount por websocket)" do
    defp hook(session) do
      socket = %Phoenix.LiveView.Socket{assigns: %{flash: %{}}}
      DranWeb.LiveAuth.on_mount(:require_instance_admin, %{}, session, socket)
    end

    # `push_navigate/2` devuelve el socket con el redirect anotado, no una tupla.
    defp destino({:halt, %Phoenix.LiveView.Socket{redirected: {:live, :redirect, %{to: to}}}}),
      do: to

    defp destino({:cont, _socket}), do: :cont

    test "el dueño continúa" do
      owner = user!("socket_owner@test.dev", %{is_owner: true})

      assert destino(hook(%{"user" => owner.email, "is_owner" => true})) == :cont
    end

    test "el admin de instancia continúa" do
      admin = user!("socket_admin@test.dev") |> with_role("admin")

      assert destino(hook(%{"user" => admin.email, "is_owner" => false})) == :cont
    end

    test "el usuario normal se va al home" do
      viewer = user!("socket_viewer@test.dev") |> with_role("viewer")

      assert destino(hook(%{"user" => viewer.email, "is_owner" => false})) == "/"
    end

    test "sin usuario, al login" do
      assert destino(hook(%{})) == "/login"
    end
  end
end
