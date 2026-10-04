defmodule DranWeb.AdminSystemLiveTest do
  @moduledoc """
  El estado de la integración de SERVICIOS en `/admin/system`: configurado o no
  (read-only), el valor de la clave NUNCA, y un «Probar conexión» que informa el
  resultado real — el que devuelve el proveedor, no un optimismo local.
  """

  use DranWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Dran.Composio

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

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user, "test_user")
      |> Plug.Conn.put_session(:is_owner, true)

    {:ok, conn: conn}
  end

  describe "la integración de servicios" do
    test "sin key de instancia lo dice y no ofrece valor alguno", %{conn: conn} do
      Application.delete_env(:dran, :composio)

      {:ok, view, html} = live(conn, ~p"/admin/system")

      assert html =~ t("Services")
      assert html =~ t("Not configured")
      assert html =~ "DRAN_COMPOSIO_API_KEY"
      # La UI muestra ESTADO, nunca el valor (la fila de la clave dice "—").
      assert has_element?(view, "#services-key-state", "—")
      refute has_element?(view, "#services-key-state", "••••••••")
    end

    test "configurada: estado y máscara, jamás la clave", %{conn: conn} do
      composio_env()

      {:ok, view, html} = live(conn, ~p"/admin/system")

      assert html =~ t("Configured")
      assert has_element?(view, "#services-key-state", "••••••••")
      refute html =~ "test-instance-key"
    end

    test "probar conexión informa el resultado real del proveedor", %{conn: conn} do
      composio_env()

      Req.Test.stub(Composio, fn conn ->
        Req.Test.json(conn, %{"items" => [%{"id" => "ca_1"}]})
      end)

      {:ok, view, _html} = live(conn, ~p"/admin/system")

      html =
        view
        |> element("#services-test-connection")
        |> render_click()
        |> then(fn _ -> await(view, t("Responds")) end)

      assert html =~ t("Responds")
      assert html =~ "1"
    end

    test "probar conexión informa el error real, no un éxito", %{conn: conn} do
      composio_env()

      Req.Test.stub(Composio, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(500, Jason.encode!(%{"message" => "boom"}))
      end)

      {:ok, view, _html} = live(conn, ~p"/admin/system")

      view |> element("#services-test-connection") |> render_click()
      html = await(view, t("Offline"))

      assert html =~ t("Offline")
      assert html =~ "500"

      assert html =~
               Gettext.gettext(DranWeb.Gettext, "The provider answered %{status}", status: 500)
    end

    test "sin key, probar conexión no sale a la red y lo dice", %{conn: conn} do
      Application.delete_env(:dran, :composio)

      # Sin stub: si algo intentara hablar con el proveedor, Req.Test explota.
      {:ok, view, _html} = live(conn, ~p"/admin/system")

      view |> element("#services-test-connection") |> render_click()
      html = await(view, t("Key not configured"))

      assert html =~ t("Key not configured")
    end
  end

  # El resultado llega por mensaje desde un Task: se espera sincronizando con el
  # proceso del LiveView (`:sys.get_state/1`), nunca durmiendo.
  defp await(view, text, tries \\ 100) do
    html = render(view)

    cond do
      html =~ text ->
        html

      tries == 0 ->
        flunk("never rendered #{inspect(text)}")

      true ->
        _ = :sys.get_state(view.pid)
        await(view, text, tries - 1)
    end
  end

  defp composio_env do
    Application.put_env(:dran, :composio,
      base_url: "https://backend.composio.dev",
      api_key: "test-instance-key",
      timeout: 5_000,
      req_plug: {Req.Test, Dran.Composio}
    )
  end
end
