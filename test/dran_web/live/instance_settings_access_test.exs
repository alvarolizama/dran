defmodule DranWeb.InstanceSettingsAccessTest do
  @moduledoc """
  `/admin/instance` es administración de la INSTANCIA y su guard es el DUEÑO:
  entra el owner de la instancia y nadie más (es la regla de todo `/admin/*`,
  `pipeline :admin`). Un `instance_role` admin ya no entra: configurar la
  instancia es política del dueño.

  La guardia vive en la ruta (`pipeline :admin` + `require_instance_owner/2`) y
  su gemelo en el socket (`LiveAuth.on_mount(:require_admin, ...)`), no en la
  página. La matriz se prueba por los DOS caminos: la petición HTTP + el mount
  del LiveView (`live/2` corre los plugs y el `on_mount`) y el hook suelto, que
  es el que cubre el re-mount por websocket.

  La URL vieja (`/settings/instance`) queda viva como hop al destino nuevo.
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

  describe "la ruta (/admin/instance)" do
    test "el dueño de la instancia entra", %{conn: conn} do
      owner = user!("instance_owner@test.dev", %{is_owner: true})
      conn = session_conn(conn, owner.email, true)

      {:ok, _view, html} = live(conn, ~p"/admin/instance")

      assert html =~ "Instance settings"
    end

    test "un admin de instancia NO entra: la configuración es del dueño", %{conn: conn} do
      admin = user!("instance_admin@test.dev") |> with_role("admin")
      conn = session_conn(conn, admin.email, false)

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin/instance")
    end

    test "un usuario normal (viewer) NO entra: vuelve al home", %{conn: conn} do
      viewer = user!("instance_viewer@test.dev") |> with_role("viewer")
      conn = session_conn(conn, viewer.email, false)

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin/instance")
    end

    test "un editor tampoco: no es rol de administración", %{conn: conn} do
      editor = user!("instance_editor@test.dev") |> with_role("editor")
      conn = session_conn(conn, editor.email, false)

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin/instance")
    end

    test "una sesión sin usuario va al login", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/admin/instance")
    end

    # El plug de /admin/* decide con la bandera que el login cachea en la sesión
    # — igual que el resto del shell de administración — así que una sesión con
    # `is_owner: false` explícito queda afuera aunque su fila traiga un
    # `instance_role` de administración.
    test "una sesión con is_owner: false explícito no entra", %{conn: conn} do
      admin = user!("flag_false@test.dev", %{is_owner: false}) |> with_role("admin")
      conn = session_conn(conn, admin.email, false)

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin/instance")
    end
  end

  describe "la URL vieja (/settings/instance)" do
    test "redirige al destino nuevo", %{conn: conn} do
      owner = user!("legacy_owner@test.dev", %{is_owner: true})

      conn =
        conn
        |> session_conn(owner.email, true)
        |> get(~p"/settings/instance")

      assert redirected_to(conn) == ~p"/admin/instance"
    end

    test "sin sesión va al login", %{conn: conn} do
      conn = get(conn, ~p"/settings/instance")

      assert redirected_to(conn) == ~p"/login"
    end
  end

  describe "el nav muestra Instance settings sólo al dueño" do
    # El guard admite al dueño EN CUALQUIER página, así que el ítem del nav no
    # puede depender de dónde esté parado el lector — y los dos hablan del dueño:
    # la página vive en el grupo Admin (`/admin/instance`) y el menú de perfil
    # repite el mismo grupo, que es owner-only.
    test "el dueño ve el enlace en /settings/account", %{conn: conn} do
      owner = user!("nav_owner@test.dev", %{is_owner: true})
      conn = session_conn(conn, owner.email, true)

      {:ok, view, _html} = live(conn, ~p"/settings/account")

      assert has_element?(view, "aside a[href='/admin/instance']")
    end

    test "el dueño ve el enlace también en una página de conocimiento", %{conn: conn} do
      owner = user!("nav_owner_knowledge@test.dev", %{is_owner: true})
      conn = session_conn(conn, owner.email, true)

      {:ok, view, _html} = live(conn, ~p"/notes")

      assert has_element?(view, "#user-menu a[href='/admin/instance']")
    end

    test "un admin de instancia no lo ve en ninguna de las dos", %{conn: conn} do
      admin = user!("nav_admin@test.dev") |> with_role("admin")
      conn = session_conn(conn, admin.email, false)

      {:ok, view_account, _html} = live(conn, ~p"/settings/account")
      {:ok, view_notes, _html} = live(conn, ~p"/notes")

      refute has_element?(view_account, "aside a[href='/admin/instance']")
      refute has_element?(view_notes, "#user-menu a[href='/admin/instance']")
    end

    test "un viewer no lo ve en ninguna de las dos", %{conn: conn} do
      viewer = user!("nav_viewer@test.dev") |> with_role("viewer")
      conn = session_conn(conn, viewer.email, false)

      {:ok, view_account, _html} = live(conn, ~p"/settings/account")
      {:ok, view_notes, _html} = live(conn, ~p"/notes")

      refute has_element?(view_account, "aside a[href='/admin/instance']")
      refute has_element?(view_notes, "#user-menu a[href='/admin/instance']")
    end
  end

  describe "el gemelo del socket (re-mount por websocket)" do
    defp hook(session) do
      socket = %Phoenix.LiveView.Socket{assigns: %{flash: %{}}}
      DranWeb.LiveAuth.on_mount(:require_admin, %{}, session, socket)
    end

    # `push_navigate/2` devuelve el socket con el redirect anotado, no una tupla.
    defp destino({:halt, %Phoenix.LiveView.Socket{redirected: {:live, :redirect, %{to: to}}}}),
      do: to

    defp destino({:cont, _socket}), do: :cont

    test "el dueño continúa" do
      owner = user!("socket_owner@test.dev", %{is_owner: true})

      assert destino(hook(%{"user" => owner.email, "is_owner" => true})) == :cont
    end

    test "el admin de instancia se va al home" do
      admin = user!("socket_admin@test.dev") |> with_role("admin")

      assert destino(hook(%{"user" => admin.email, "is_owner" => false})) == "/"
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
