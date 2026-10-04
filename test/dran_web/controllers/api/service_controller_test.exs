defmodule DranWeb.API.ServiceControllerTest do
  @moduledoc """
  Gate de la W2: el link es de la SESIÓN, la identidad no llega del cliente y el
  callback no prueba nada.

  La regla que gobierna estos tests es una sola: los query params de una vuelta
  OAuth son INPUT, no prueba de propiedad (F/§Constraints#7). Lo que el usuario
  tiene conectado lo dicta la próxima lectura al servidor.
  """

  use DranWeb.ConnCase, async: false

  alias Dran.Accounts
  alias Dran.Composio
  alias Dran.Services

  setup do
    original = Application.get_env(:dran, :composio)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:dran, :composio)
      else
        Application.put_env(:dran, :composio, original)
      end
    end)

    unique = System.unique_integer([:positive])

    {:ok, alice} = Accounts.create_user(%{email: "alice-#{unique}@example.com", name: "Alice"})
    {:ok, bob} = Accounts.create_user(%{email: "bob-#{unique}@example.com", name: "Bob"})

    Application.put_env(:dran, :composio,
      base_url: "https://backend.composio.dev",
      api_key: "test-instance-key",
      timeout: 5_000,
      req_plug: {Req.Test, Dran.Composio}
    )

    Services.put_allowlist(["gmail"])

    %{
      alice: alice,
      bob: bob,
      unique: unique,
      api_conn: api_conn(alice),
      bob_conn: api_conn(bob),
      browser_conn: browser_conn(alice)
    }
  end

  # ── Autenticación ──────────────────────────────────────────────────────────

  describe "autenticación" do
    test "sin token no hay link ni borrado", %{unique: unique} do
      conn = build_conn() |> Plug.Conn.put_req_header("accept", "application/json")

      assert %{"errors" => _} = json_response(post(conn, "/api/services/gmail/connect", %{}), 401)

      conn = build_conn() |> Plug.Conn.put_req_header("accept", "application/json")
      assert %{"errors" => _} = json_response(delete(conn, "/api/services/gmail"), 401)
      assert is_integer(unique)
    end

    test "sin key de instancia todo falla cerrado", %{api_conn: conn} do
      Application.delete_env(:dran, :composio)

      body = json_response(post(conn, "/api/services/gmail/connect", %{}), 503)
      assert body["errors"]["code"] == "not_configured"

      body = json_response(delete(conn, "/api/services/gmail"), 503)
      assert body["errors"]["code"] == "not_configured"
    end
  end

  # ── P5: nada del cliente elige de quién es la sesión ───────────────────────

  describe "POST /api/services/:toolkit/connect" do
    test "el payload con user_id y session_id no cambia de quién es la sesión",
         %{api_conn: conn, alice: alice, bob: bob} do
      stub_composio(%{accounts: [account("gmail", alice.id, "INITIATED", "alice@gmail.com")]})

      body =
        json_response(
          post(conn, "/api/services/gmail/connect", %{
            "user_id" => to_string(bob.id),
            "session_id" => "trs_forged",
            "toolkit" => "gmail"
          }),
          201
        )

      assert body["data"]["redirect_url"] == "https://app.composio.dev/link/abc"
      assert body["data"]["expires_in"] == 600

      # La sesión se creó para ALICE (el token), no para el user_id del body.
      assert_receive {:composio, "POST", "/api/v3.1/tool_router/session", _params,
                      %{"user_id" => user_id}}

      assert user_id == to_string(alice.id)

      # …y el link salió de ESA sesión: el `trs_forged` del cliente nunca se usa.
      assert_receive {:composio, "POST", "/api/v3.1/tool_router/session/trs_reader/link", _params,
                      link_body}

      refute Map.has_key?(link_body, "user_id")
      refute Map.has_key?(link_body, "session_id")
    end

    test "el link es de la sesión: toolkit + callback de la instancia, nada más",
         %{api_conn: conn, alice: alice} do
      stub_composio(%{accounts: [account("gmail", alice.id, "INITIATED", "alice@gmail.com")]})

      post(conn, "/api/services/gmail/connect", %{})

      assert_receive {:composio, "POST", "/api/v3.1/tool_router/session/trs_reader/link", _params,
                      body}

      assert Map.keys(body) |> Enum.sort() == ["callback_url", "toolkit"]
      assert body["toolkit"] == "gmail"
      # La URL de vuelta la fija el servidor: es la superficie de ESTA instancia.
      assert body["callback_url"] == DranWeb.Endpoint.url() <> "/services/callback"
      assert body["callback_url"] == Services.callback_url()
    end

    test "un toolkit fuera de la allowlist no conecta ni llama al vendor",
         %{api_conn: conn} do
      stub_composio(%{})

      body = json_response(post(conn, "/api/services/slack/connect", %{}), 403)
      assert body["errors"]["code"] == "not_allowed"

      refute_receive {:composio, _, _, _, _}
      # Y la allowlist sigue siendo la del owner.
      assert Services.allowlist() == ["gmail"]
    end
  end

  # ── P6: el callback forjado no cambia el estado ────────────────────────────

  describe "GET /services/callback" do
    test "un callback forjado con status=ACTIVE no cambia nada",
         %{browser_conn: conn, api_conn: api_conn, alice: alice} do
      # El vendor sigue diciendo INITIATED: el consentimiento no se completó.
      stub_composio(%{accounts: [account("gmail", alice.id, "INITIATED", "alice@gmail.com")]})

      forged =
        get(
          conn,
          "/services/callback?toolkit=gmail&status=ACTIVE&connected_account_id=ca_forged&user_id=#{alice.id}"
        )

      assert redirected_to(forged) == "/services?returned=1"

      # …y el estado real sigue siendo el del servidor.
      body = json_response(get(api_conn, "/api/services"), 200)
      [gmail] = body["data"]
      assert gmail["status"] == "INITIATED"
      assert gmail["connected"] == true

      refute Jason.encode!(body) =~ "ca_forged"
    end

    test "sin sesión de navegador no aterriza: fail-closed", %{alice: alice} do
      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> get("/services/callback?status=ACTIVE")

      assert redirected_to(conn) == "/login"
      assert is_integer(alice.id)
    end
  end

  # ── P7 y Q16: desconectar borra, y solo lo propio ─────────────────────────

  describe "DELETE /api/services/:toolkit" do
    test "borra con revoke_on_delete=true", %{api_conn: conn, alice: alice} do
      stub_composio(%{accounts: [account("gmail", alice.id, "ACTIVE", "alice@gmail.com")]})

      body = json_response(delete(conn, "/api/services/gmail"), 200)

      assert body["data"]["toolkit"] == "gmail"
      assert body["data"]["disconnected"] == true
      assert body["data"]["revoked"] == 1

      assert_receive {:composio, "DELETE", "/api/v3.1/connected_accounts/ca_alice", params, _}
      assert params["revoke_on_delete"] == "true"
    end

    test "el owner no borra la conexión de otro: no hay nada que borrar",
         %{bob_conn: conn, alice: alice, unique: unique} do
      # El stub sirve la lista del PROYECTO (la de alice) a quien pregunte.
      stub_composio(%{accounts: [account("gmail", alice.id, "ACTIVE", "alice@gmail.com")]})

      body = json_response(delete(conn, "/api/services/gmail"), 200)

      assert body["data"]["disconnected"] == false
      assert body["data"]["revoked"] == 0
      refute_received {:composio, "DELETE", _, _, _}
      assert is_integer(unique)
    end

    test "sin conexión el borrado es un no-op idempotente", %{api_conn: conn} do
      stub_composio(%{accounts: []})

      body = json_response(delete(conn, "/api/services/gmail"), 200)
      assert body["data"]["disconnected"] == false
      refute_received {:composio, "DELETE", _, _, _}
    end

    test "un toolkit fuera de la allowlist no se toca", %{api_conn: conn} do
      stub_composio(%{})

      body = json_response(delete(conn, "/api/services/slack"), 403)
      assert body["errors"]["code"] == "not_allowed"
      refute_receive {:composio, _, _, _, _}
    end
  end

  # ── W4: descubrir y ejecutar por HTTP ──────────────────────────────────────

  describe "GET /api/services/:toolkit/tools" do
    test "el catálogo del toolkit, y el esquema completo con ?slug", %{
      api_conn: conn,
      alice: alice
    } do
      stub_composio(%{accounts: [account("gmail", alice.id, "ACTIVE", "alice@gmail.com")]})

      body = json_response(get(conn, "/api/services/gmail/tools"), 200)
      assert body["data"]["toolkit"] == "gmail"
      assert [%{"slug" => "GMAIL_SEND_EMAIL"}] = body["data"]["tools"]
      refute Map.has_key?(hd(body["data"]["tools"]), "input_parameters")

      full = json_response(get(conn, "/api/services/gmail/tools?slug=GMAIL_SEND_EMAIL"), 200)
      [tool] = full["data"]["tools"]
      assert tool["input_parameters"]["to"]["required"] == true
    end

    test "un toolkit fuera de la allowlist no cataloga", %{api_conn: conn} do
      stub_composio(%{})

      body = json_response(get(conn, "/api/services/slack/tools"), 403)
      assert body["errors"]["code"] == "not_allowed"
      refute_receive {:composio, _, _, _, _}
    end
  end

  describe "GET /api/services/search" do
    test "la búsqueda por caso de uso", %{api_conn: conn} do
      stub_composio(%{})

      body = json_response(get(conn, "/api/services/search?q=send+an+email"), 200)
      assert body["data"]["primary_tool_slugs"] == ["GMAIL_SEND_EMAIL"]
      assert body["data"]["query"] == "send an email"
    end

    test "sin q es un 422 explícito", %{api_conn: conn} do
      body = json_response(get(conn, "/api/services/search"), 422)
      assert body["errors"]["code"] == "missing_query"
    end
  end

  describe "POST /api/services/execute" do
    test "ejecuta, responde con el log_id y registra el agente", %{api_conn: conn, alice: alice} do
      stub_composio(%{accounts: [account("gmail", alice.id, "ACTIVE", "alice@gmail.com")]})

      body =
        json_response(
          post(conn, "/api/services/execute", %{
            "toolkit" => "gmail",
            "tool_slug" => "GMAIL_SEND_EMAIL",
            "arguments" => %{"to" => "x@y.z"}
          }),
          200
        )

      assert body["data"]["log_id"] == "log_1"
      assert body["data"]["result"] == %{"sent" => true}

      assert_receive {:composio, "POST", "/api/v3.1/tool_router/session/trs_reader/execute", _,
                      payload}

      assert payload["tool_slug"] == "GMAIL_SEND_EMAIL"
      # El agent_name sale del header, resuelto en el borde.
      [call] = Dran.Services.Call.recent(alice.id)
      assert call.agent_name == "agent-test"
    end

    test "sin conexión ACTIVE: 409 con el link, no el error del vendor", %{
      api_conn: conn,
      alice: alice
    } do
      stub_composio(%{accounts: [account("gmail", alice.id, "EXPIRED", "alice@gmail.com")]})

      body =
        json_response(
          post(conn, "/api/services/execute", %{
            "toolkit" => "gmail",
            "tool_slug" => "GMAIL_SEND_EMAIL",
            "arguments" => %{}
          }),
          409
        )

      assert body["errors"]["code"] == "not_connected"
      assert body["status"] == "EXPIRED"
      assert body["connect_url"] == "https://app.composio.dev/link/abc"
    end

    test "sin tool_slug: 422 y ninguna llamada", %{api_conn: conn} do
      stub_composio(%{})

      body = json_response(post(conn, "/api/services/execute", %{"toolkit" => "gmail"}), 422)
      assert body["errors"]["code"] == "missing_tool"
      refute_receive {:composio, _, _, _, _}
    end

    test "sin token no ejecuta", %{alice: alice} do
      conn = build_conn() |> Plug.Conn.put_req_header("accept", "application/json")

      assert %{"errors" => _} =
               json_response(
                 post(conn, "/api/services/execute", %{"toolkit" => "gmail", "tool_slug" => "X"}),
                 401
               )

      assert is_integer(alice.id)
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp api_conn(user) do
    build_conn()
    |> Plug.Conn.put_req_header("accept", "application/json")
    |> Plug.Conn.put_req_header("authorization", "Bearer #{user.api_token}")
    |> Plug.Conn.put_req_header("x-hermes-agent", "agent-test")
  end

  defp browser_conn(user) do
    build_conn()
    |> Plug.Test.init_test_session(%{"user" => user.email, "is_owner" => false})
  end

  defp stub_composio(opts) do
    test_pid = self()
    accounts = Map.get(opts, :accounts, [])

    Req.Test.stub(Composio, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      payload = if raw == "", do: %{}, else: Jason.decode!(raw)

      send(
        test_pid,
        {:composio, conn.method, conn.request_path, decode_query(conn), payload}
      )

      case {conn.method, conn.request_path} do
        {"POST", "/api/v3.1/tool_router/session"} ->
          Req.Test.json(conn, %{"session_id" => "trs_reader"})

        {"POST", "/api/v3.1/tool_router/session/trs_reader/link"} ->
          Req.Test.json(conn, %{
            "redirect_url" => "https://app.composio.dev/link/abc",
            "link_token" => "lt_1"
          })

        {"GET", "/api/v3.1/connected_accounts"} ->
          Req.Test.json(conn, %{"items" => accounts})

        {"DELETE", "/api/v3.1/connected_accounts/ca_alice"} ->
          Req.Test.json(conn, %{"revoke_job_id" => "job_1"})

        {"GET", "/api/v3.1/toolkits"} ->
          Req.Test.json(conn, %{
            "items" => [
              %{"slug" => "gmail", "name" => "Gmail", "meta" => %{"description" => "Email"}}
            ]
          })

        {"GET", "/api/v3.1/tool_router/session/trs_reader/tools"} ->
          Req.Test.json(conn, %{
            "items" => [
              %{
                "slug" => "GMAIL_SEND_EMAIL",
                "name" => "Send email",
                "description" => "Send an email",
                "input_parameters" => %{"to" => %{"type" => "string", "required" => true}},
                "output_parameters" => %{}
              }
            ]
          })

        {"POST", "/api/v3.1/tool_router/session/trs_reader/search"} ->
          Req.Test.json(conn, %{
            "results" => [
              %{
                "primary_tool_slugs" => ["GMAIL_SEND_EMAIL"],
                "related_tool_slugs" => [],
                "recommended_plan_steps" => ["Compose it"],
                "known_pitfalls" => nil
              }
            ]
          })

        {"POST", "/api/v3.1/tool_router/session/trs_reader/execute"} ->
          Req.Test.json(conn, %{"log_id" => "log_1", "data" => %{"sent" => true}})
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
      "id" => "ca_alice",
      "user_id" => to_string(user_id),
      "status" => status,
      "toolkit" => %{"slug" => toolkit},
      "state" => %{"val" => %{"displayName" => display_name}}
    }
  end
end
