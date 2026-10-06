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

  # El catálogo se elige por locale en la petición, así que el texto se pide al
  # backend en vez de escribirlo literal.
  defp t(msgid), do: Gettext.gettext(DranWeb.Gettext, msgid)

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

      {:ok, view, _html} = live(conn, ~p"/admin/instance")

      # El título de la página es el del enlace del nav (Admin › Settings).
      assert view |> element("#settings-title") |> render() =~ t("Settings")
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

  describe "el nav muestra Settings sólo al dueño" do
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

  describe "la credencial de la instancia vive acá (mudada de /admin/system)" do
    # Fase 0: el token admin legacy es la credencial DE LA INSTANCIA, así que se
    # emite y se rota bajo su nombre (tab General). El setting NO cambia
    # (`settings['api_token']`): es una mudanza de la puerta, no del modelo.
    test "el tab General la emite: campo editable + Generate", %{conn: conn} do
      owner = user!("instance_token_owner@test.dev", %{is_owner: true})
      conn = session_conn(conn, owner.email, true)

      {:ok, view, _html} = live(conn, ~p"/admin/instance")

      # Bajo el nombre (el tab General abre por defecto).
      assert has_element?(view, "#general-section")
      assert has_element?(view, "#instance-token-section")
      assert has_element?(view, "#instance-form")
      assert has_element?(view, "#instance_api_token")
      assert has_element?(view, "#generate-instance-token")
    end

    test "guardar un token a mano lo persiste y vaciarlo lo deshabilita", %{conn: conn} do
      owner = user!("instance_token_save@test.dev", %{is_owner: true})
      conn = session_conn(conn, owner.email, true)

      {:ok, view, _html} = live(conn, ~p"/admin/instance")

      html =
        render_submit(view, "save_instance", %{
          "instance" => %{"api_token" => "instancia-test-token"}
        })

      assert html =~ t("Instance configuration saved.")
      assert Dran.Settings.get("api_token") == "instancia-test-token"
      # El token guardado AUTENTICA: es el mismo camino que usa un cliente real.
      assert bearer_status("instancia-test-token") == 200

      # Vacío = deshabilitado, y el bearer deja de entrar en el acto.
      render_submit(view, "save_instance", %{"instance" => %{"api_token" => ""}})

      assert is_nil(Dran.Settings.get("api_token"))
      assert bearer_status("instancia-test-token") == 401
    end

    test "Generate emite un token aleatorio que autentica contra el API", %{conn: conn} do
      owner = user!("instance_token_generate@test.dev", %{is_owner: true})
      conn = session_conn(conn, owner.email, true)

      {:ok, view, _html} = live(conn, ~p"/admin/instance")

      html = render_click(view, "generate_token")

      assert html =~ t("Token generated and copied to the clipboard.")
      token = Dran.Settings.get("api_token")
      assert is_binary(token) and byte_size(token) >= 20
      assert bearer_status(token) == 200
    end
  end

  # El bearer contra el API, como un cliente real: el status es la prueba.
  defp bearer_status(token) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("accept", "application/json")
    |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
    |> get("/api/agent/config")
    |> Map.fetch!(:status)
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
