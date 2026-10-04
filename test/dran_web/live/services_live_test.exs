defmodule DranWeb.ServicesLiveTest do
  @moduledoc """
  Gate de la W3: la sección `/services` con el estado real, la identidad del
  proveedor, el shell compartido y las acciones del vocabulario.

  Lo que NO puede aparecer es igual de importante: ningún id crudo del vendor
  (`trs_…`, `ca_…`, `ac_…`) y ninguna credencial del proveedor.
  """

  use DranWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Dran.Composio
  alias Dran.Services

  # Gettext wrapper: el inglés es el idioma por defecto de la app, así que el
  # msgid es lo que se renderiza.
  defp t(msgid), do: Gettext.gettext(DranWeb.Gettext, msgid)

  setup %{conn: conn} do
    original = Application.get_env(:dran, :composio)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:dran, :composio)
      else
        Application.put_env(:dran, :composio, original)
      end
    end)

    Application.put_env(:dran, :composio,
      base_url: "https://backend.composio.dev",
      api_key: "test-instance-key",
      timeout: 5_000,
      req_plug: {Req.Test, Dran.Composio}
    )

    user = Dran.Accounts.get_user_by_email("test_user")

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user, "test_user")
      |> Plug.Conn.put_session(:workspace_slug, "personal")
      |> Plug.Conn.put_session(:is_owner, true)

    {:ok, conn: conn, user: user}
  end

  describe "la sección" do
    setup do
      Services.put_allowlist(["gmail", "github"])
      :ok
    end

    test "lista cada servicio con su estado y la identidad del proveedor",
         %{conn: conn, user: user} do
      stub_composio(%{accounts: [account("gmail", user.id, "ACTIVE", "soy@example.com")]})

      {:ok, view, html} = live(conn, ~p"/services")

      assert html =~ t("Services")
      assert has_element?(view, "#services-list")
      assert has_element?(view, "#service-card-gmail")
      assert has_element?(view, "#service-card-github")

      # El estado del ciclo de vida y la identidad real del proveedor.
      assert has_element?(view, "#service-card-gmail", t("Connected"))
      assert has_element?(view, "#service-card-gmail", "soy@example.com")
      assert has_element?(view, "#service-card-github", t("Not connected"))

      # Ni un id crudo del vendor, ni una credencial del proveedor.
      refute html =~ "trs_"
      refute html =~ "ca_"
      refute html =~ "access_token"
    end

    test "un estado vencido se muestra como vencido, no como conectado",
         %{conn: conn, user: user} do
      stub_composio(%{accounts: [account("gmail", user.id, "EXPIRED", "soy@example.com")]})

      {:ok, view, _html} = live(conn, ~p"/services")

      assert has_element?(view, "#service-card-gmail", t("Expired"))
      refute has_element?(view, "#service-card-gmail", t("Connected"))
    end

    test "el diálogo se abre por estado de URL y ofrece el vocabulario correcto",
         %{conn: conn, user: user} do
      stub_composio(%{accounts: [account("gmail", user.id, "ACTIVE", "soy@example.com")]})

      # Conectado: reconectar (link NUEVO) y desconectar (con advertencia).
      {:ok, view, _html} = live(conn, ~p"/services?toolkit=gmail")

      assert has_element?(view, "#service-manage-modal")
      assert has_element?(view, "#reconnect-gmail")
      assert has_element?(view, "#disconnect-gmail")

      # La advertencia de irreversibilidad va ANTES de borrar.
      warning = view |> element("#disconnect-gmail") |> render() |> String.downcase()
      assert warning =~ "cannot be undone"

      # Sin conexión: conectar.
      {:ok, view, _html} = live(conn, ~p"/services?toolkit=github")
      assert has_element?(view, "#connect-github")
      refute has_element?(view, "#disconnect-github")
    end
  end

  describe "acciones" do
    setup do
      Services.put_allowlist(["gmail"])
      :ok
    end

    test "conectar manda al navegador al link hospedado", %{conn: conn} do
      stub_composio(%{accounts: []})

      {:ok, view, _html} = live(conn, ~p"/services?toolkit=gmail")

      # El consentimiento lo hospeda el proveedor: no hay UI propia que lo finja.
      assert {:error, {:redirect, %{to: "https://app.composio.dev/link/abc"}}} =
               view |> element("#connect-gmail") |> render_click()
    end

    test "desconectar borra con revoke y refresca el estado",
         %{conn: conn, user: user} do
      stub_composio(%{accounts: [account("gmail", user.id, "ACTIVE", "soy@example.com")]})

      {:ok, view, _html} = live(conn, ~p"/services?toolkit=gmail")

      render_click(element(view, "#disconnect-gmail"))

      assert_received {:composio, "DELETE", "/api/v3.1/connected_accounts/ca_test", params, _}
      assert params["revoke_on_delete"] == "true"

      assert render(view) =~ t("Service disconnected.")
    end
  end

  describe "sin servicios expuestos" do
    setup do
      Services.put_allowlist([])
      :ok
    end

    test "el empty state compartido, no una lista vacía", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/services")

      assert has_element?(view, "[data-testid=empty-state]")
      refute has_element?(view, "#services-list")
      assert html =~ t("No services exposed")
      # El CTA lleva a la política de instancia (no hay modal de alta acá).
      assert has_element?(view, "[data-testid=empty-state] a[href=\"/admin/instance\"]")
    end
  end

  describe "sin la integración configurada" do
    test "lo dice, no explota y no lista nada", %{conn: conn} do
      Application.delete_env(:dran, :composio)
      Services.put_allowlist(["gmail"])

      {:ok, view, _html} = live(conn, ~p"/services")

      assert has_element?(view, "#services-not-configured")
      refute has_element?(view, "#services-list")
      refute has_element?(view, "[data-testid=empty-state]")
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp stub_composio(opts) do
    test_pid = self()
    accounts = Map.get(opts, :accounts, [])

    Req.Test.stub(Composio, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      payload = if raw == "", do: %{}, else: Jason.decode!(raw)

      send(test_pid, {:composio, conn.method, conn.request_path, decode_query(conn), payload})

      case {conn.method, conn.request_path} do
        {"POST", "/api/v3.1/tool_router/session"} ->
          Req.Test.json(conn, %{"session_id" => "trs_test"})

        {"POST", "/api/v3.1/tool_router/session/trs_test/link"} ->
          Req.Test.json(conn, %{
            "redirect_url" => "https://app.composio.dev/link/abc",
            "link_token" => "lt_1"
          })

        {"GET", "/api/v3.1/connected_accounts"} ->
          Req.Test.json(conn, %{"items" => accounts})

        {"DELETE", "/api/v3.1/connected_accounts/ca_test"} ->
          Req.Test.json(conn, %{"revoke_job_id" => "job_1"})

        {"GET", "/api/v3.1/toolkits"} ->
          Req.Test.json(conn, %{
            "items" => [
              %{"slug" => "gmail", "name" => "Gmail", "meta" => %{"description" => "Email"}},
              %{"slug" => "github", "name" => "GitHub"}
            ]
          })
      end
    end)
  end

  defp decode_query(conn) do
    case conn.query_string do
      "" -> %{}
      qs -> Plug.Conn.Query.decode(qs)
    end
  end

  defp account(toolkit, user_id, status, display_name) do
    %{
      "id" => "ca_test",
      "user_id" => to_string(user_id),
      "status" => status,
      "toolkit" => %{"slug" => toolkit},
      "state" => %{"val" => %{"displayName" => display_name}}
    }
  end
end
