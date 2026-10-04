defmodule DranWeb.ServicesAllowlistTest do
  @moduledoc """
  La allowlist de SERVICIOS es política de INSTANCIA y del owner: se edita en
  Instance settings → Servicios, y decide qué apps puede conectar la gente.

  Lo que no esté en la lista no se lista, no se cataloga y no ejecuta (P10), así
  que la puerta de esta pantalla importa tanto como el guardado.
  """

  use DranWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Dran.Accounts
  alias Dran.Services

  defp t(msgid), do: Gettext.gettext(DranWeb.Gettext, msgid)

  setup do
    original = Dran.Settings.get("service_toolkits")

    on_exit(fn ->
      if is_nil(original) do
        Dran.Settings.delete("service_toolkits")
      else
        Dran.Settings.put("service_toolkits", original)
      end
    end)

    :ok
  end

  defp session_conn(conn, email, is_owner) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:user, email)
    |> Plug.Conn.put_session(:workspace_slug, "personal")
    |> Plug.Conn.put_session(:is_owner, is_owner)
  end

  describe "Instance settings → Servicios" do
    test "el owner guarda la lista y se normaliza", %{conn: conn} do
      {:ok, view, _html} = live(session_conn(conn, "test_user", true), ~p"/admin/instance")

      tab = view |> element(~s{button[phx-value-tab="services"]}) |> render_click()
      assert tab =~ t("Exposed services")

      html =
        view
        |> element("#services-allowlist-form")
        |> render_submit(%{"services" => %{"toolkits" => " Gmail, github ,gmail,slack "}})

      # Normalizada (minúsculas, sin duplicados, sin espacios) y persistida.
      assert Services.allowlist() == ["gmail", "github", "slack"]
      assert html =~ t("Settings saved")
      # El formulario vuelve con el valor guardado.
      assert html =~ "gmail, github, slack"
    end

    test "vaciar la lista apaga la superficie (nada expuesto)", %{conn: conn} do
      Services.put_allowlist(["gmail"])

      {:ok, view, _html} = live(session_conn(conn, "test_user", true), ~p"/admin/instance")

      view |> element(~s{button[phx-value-tab="services"]}) |> render_click()

      view
      |> element("#services-allowlist-form")
      |> render_submit(%{"services" => %{"toolkits" => ""}})

      assert Services.allowlist() == []
    end

    test "un usuario normal no entra a Instance settings", %{conn: conn} do
      unique = System.unique_integer([:positive])
      {:ok, user} = Accounts.create_user(%{email: "member-#{unique}@example.com", name: "Member"})

      # La guardia es de la RUTA (owner-only, como todo /admin/*): un miembro
      # común —rol por defecto, `editor`— ni siquiera monta la página.
      assert {:error, {:redirect, %{to: "/"}}} =
               live(session_conn(conn, user.email, false), ~p"/admin/instance")
    end

    test "un admin de instancia tampoco: configurar la instancia es del owner",
         %{conn: conn} do
      unique = System.unique_integer([:positive])

      {:ok, user} = Accounts.create_user(%{email: "iadmin-#{unique}@example.com", name: "Admin"})

      {:ok, user} =
        user
        |> Ecto.Changeset.change(instance_role: "admin")
        |> Dran.Repo.update()

      # La instancia se configura desde el shell de admin y ESE shell es del
      # dueño (`pipeline :admin`): un `instance_role` admin no entra, ni a la
      # página ni —por lo tanto— a la allowlist de servicios.
      assert {:error, {:redirect, %{to: "/"}}} =
               live(session_conn(conn, user.email, false), ~p"/admin/instance")
    end
  end
end
