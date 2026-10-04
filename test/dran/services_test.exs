defmodule Dran.ServicesTest do
  @moduledoc """
  Gate de la W1: aislamiento entre dos lectores, apagado fail-closed sin key y
  UNA sesión de Composio por usuario, reusada.

  El aislamiento es el gate que el propio vendor exige antes de lanzar (F24) y
  la razón es estructural: la lista de conexiones de Composio es del PROYECTO,
  no del usuario (F40). El stub devuelve las cuentas de TODOS a propósito — así
  lo que se prueba es el filtro de dran, no la buena voluntad del vendor.
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

    {:ok, alice} =
      Accounts.create_user(%{email: "alice-#{unique}@example.com", name: "Alice"})

    {:ok, bob} = Accounts.create_user(%{email: "bob-#{unique}@example.com", name: "Bob"})

    %{alice: alice, bob: bob, unique: unique}
  end

  # ── P2: sin env la integración está apagada y todo responde fail-closed ────

  describe "sin la key de instancia" do
    setup do
      Application.delete_env(:dran, :composio)
      :ok
    end

    test "enabled?/0 es false y la lectura falla cerrada", %{alice: alice} do
      refute Composio.Config.enabled?()
      refute Services.enabled?()

      assert {:error, :not_configured} = Services.list_services(alice)

      # Sin configurar, una llamada directa tampoco levanta: devuelve el error
      # tipado en vez de explotar con un nil.
      assert {:error, :not_configured} = Composio.connected_accounts(user_ids: ["1"])
      assert {:error, :not_configured} = Composio.create_session("1", ["gmail"])
    end

    test "GET /api/services responde 200 con configured:false", %{alice: alice} do
      conn =
        build_conn()
        |> Plug.Conn.put_req_header("accept", "application/json")
        |> Plug.Conn.put_req_header("authorization", "Bearer #{alice.api_token}")
        |> get("/api/services")

      assert %{"configured" => false, "data" => []} = json_response(conn, 200)
    end
  end

  # ── P1: dos lectores no se ven ─────────────────────────────────────────────

  describe "GET /api/services con la integración encendida" do
    setup do
      composio_env()
      Services.put_allowlist(["gmail", "github"])
      :ok
    end

    test "solo devuelve las conexiones del lector", %{alice: alice, bob: bob, unique: unique} do
      stub_composio(&project_stub(&1, alice, bob, unique))

      conn =
        build_conn()
        |> Plug.Conn.put_req_header("accept", "application/json")
        |> Plug.Conn.put_req_header("authorization", "Bearer #{alice.api_token}")
        |> get("/api/services")

      body = json_response(conn, 200)
      assert body["configured"] == true

      services = Map.new(body["data"], &{&1["toolkit"], &1})

      # La allowlist completa se lista, conectada o no: la sección necesita
      # poder ofrecer «conectar».
      assert Map.keys(services) |> Enum.sort() == ["github", "gmail"]

      gmail = services["gmail"]
      assert gmail["connected"] == true
      assert gmail["status"] == "ACTIVE"
      assert gmail["identity"] == "alice-#{unique}@gmail.com"
      assert gmail["name"] == "Gmail"
      assert gmail["description"] == "Email"

      # NADA de bob, y nada de id crudo del vendor.
      encoded = Jason.encode!(body)
      refute encoded =~ "bob-#{unique}"
      refute encoded =~ "ca_alice"
      refute encoded =~ "ca_bob"

      # github no está conectado: la entrada sigue existiendo, sin estado.
      assert services["github"]["connected"] == false
      assert services["github"]["status"] == nil
      assert services["github"]["identity"] == nil
    end

    test "y el otro lector ve LO SUYO, no lo del primero",
         %{alice: alice, bob: bob, unique: unique} do
      stub_composio(&project_stub(&1, alice, bob, unique))

      conn =
        build_conn()
        |> Plug.Conn.put_req_header("accept", "application/json")
        |> Plug.Conn.put_req_header("authorization", "Bearer #{bob.api_token}")
        |> get("/api/services")

      body = json_response(conn, 200)
      services = Map.new(body["data"], &{&1["toolkit"], &1})

      # El stub sirve las MISMAS filas a los dos: lo que cambia es el filtro.
      assert services["gmail"]["identity"] == "bob-#{unique}@gmail.com"
      assert services["github"]["identity"] == "bob-#{unique}"

      encoded = Jason.encode!(body)
      refute encoded =~ "alice-#{unique}"
      refute encoded =~ "ca_alice"
    end

    test "un toolkit fuera de la allowlist no aparece", %{alice: alice, unique: unique} do
      stub_composio(fn conn ->
        case conn.request_path do
          "/api/v3.1/connected_accounts" ->
            Req.Test.json(conn, %{
              "items" => [
                account("gmail", alice.id, "ACTIVE", "alice-#{unique}@gmail.com", "ca_1"),
                account("slack", alice.id, "ACTIVE", "alice-#{unique}", "ca_slack")
              ]
            })

          "/api/v3.1/toolkits" ->
            Req.Test.json(conn, %{"items" => []})
        end
      end)

      assert {:ok, services} = Services.list_services(alice)
      assert Enum.map(services, & &1.toolkit) == ["gmail", "github"]
      refute "slack" in Enum.map(services, & &1.toolkit)
    end

    test "sin allowlist declarada no se lee nada y no se llama al vendor", %{alice: alice} do
      Services.put_allowlist([])
      counter = :counters.new(1, [:write_concurrency])

      stub_composio(fn conn ->
        :counters.add(counter, 1, 1)
        Req.Test.json(conn, %{"items" => []})
      end)

      assert {:ok, []} = Services.list_services(alice)
      assert :counters.get(counter, 1) == 0
    end

    test "la allowlist acepta la cadena de comas de la UI y normaliza", %{alice: alice} do
      Services.put_allowlist(" Gmail, github ,gmail, ")

      assert Services.allowlist() == ["gmail", "github"]
      assert Services.allowed?("gmail")
      refute Services.allowed?("slack")

      stub_composio(fn conn ->
        Req.Test.json(conn, %{"items" => []})
      end)

      # `alice` sigue viendo la lista (no depende del estado de la conexión).
      assert {:ok, services} = Services.list_services(alice)
      assert Enum.map(services, & &1.toolkit) == ["gmail", "github"]
      assert Enum.map(services, & &1.name) == ["Gmail", "Github"]
    end
  end

  # ── P4: UNA sesión por usuario, reusada ────────────────────────────────────

  describe "ensure_session/1" do
    setup do
      composio_env()
      Services.put_allowlist(["gmail"])
      :ok
    end

    test "se crea una vez, se reusa y el user_id es el del lector", %{alice: alice} do
      counter = :counters.new(1, [:write_concurrency])
      test_pid = self()

      stub_composio(fn conn ->
        :counters.add(counter, 1, 1)

        assert conn.request_path == "/api/v3.1/tool_router/session"

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        # El `user_id` que sale es el del lector — nunca un valor del cliente y
        # nunca el email.
        assert Jason.decode!(body)["user_id"] == to_string(alice.id)
        send(test_pid, :create_session)

        Req.Test.json(conn, %{"session_id" => "trs_#{alice.id}"})
      end)

      assert {:ok, session} = Services.ensure_session(alice)
      assert session.composio_session_id == "trs_#{alice.id}"
      assert session.toolkits == ["gmail"]
      assert_received :create_session

      # La segunda llamada reusa: ninguna sesión nueva en el vendor.
      assert {:ok, again} = Services.ensure_session(alice)
      assert again.id == session.id
      assert :counters.get(counter, 1) == 1
      refute_received :create_session
    end

    test "cuando la allowlist cambia se PATCHea la sesión, no se recrea", %{alice: alice} do
      stub_composio(fn conn ->
        cond do
          conn.method == "POST" ->
            Req.Test.json(conn, %{"session_id" => "trs_1"})

          conn.method == "PATCH" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(self(), {:patched, Jason.decode!(body)})
            Req.Test.json(conn, %{"session_id" => "trs_1"})
        end
      end)

      assert {:ok, session} = Services.ensure_session(alice)

      Services.put_allowlist(["gmail", "github"])
      assert {:ok, updated} = Services.ensure_session(alice)

      assert updated.id == session.id
      assert updated.composio_session_id == "trs_1"
      assert updated.toolkits == ["gmail", "github"]
      assert_received {:patched, %{"toolkits" => %{"enable" => ["github"]}}}
    end

    test "una sesión que el vendor ya no conoce se recrea", %{alice: alice} do
      stub_composio(fn conn ->
        cond do
          conn.method == "POST" ->
            Req.Test.json(conn, %{"session_id" => "trs_new"})

          conn.method == "PATCH" ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.resp(404, Jason.encode!(%{"message" => "session not found"}))
        end
      end)

      # Snapshot local con una allowlist vieja para forzar el PATCH.
      assert {:ok, _} = Services.ensure_session(alice)
      Services.put_allowlist(["gmail", "github"])

      assert {:ok, session} = Services.ensure_session(alice)
      assert session.composio_session_id == "trs_new"
    end
  end

  # ── P17: la superficie no expone credenciales del proveedor ────────────────

  describe "credenciales del proveedor" do
    setup do
      composio_env()
      Services.put_allowlist(["gmail"])
      :ok
    end

    test "el payload no lleva tokens aunque el vendor los mande", %{alice: alice} do
      stub_composio(fn conn ->
        case conn.request_path do
          "/api/v3.1/connected_accounts" ->
            row =
              account("gmail", alice.id, "ACTIVE", "alice@gmail.com", "ca_1")
              |> Map.put("access_token", "gho_super_secret")
              |> Map.put("state", %{
                "val" => %{"displayName" => "alice@gmail.com", "access_token" => "secret"}
              })

            Req.Test.json(conn, %{"items" => [row]})

          "/api/v3.1/toolkits" ->
            Req.Test.json(conn, %{"items" => []})
        end
      end)

      assert {:ok, services} = Services.list_services(alice)
      encoded = Jason.encode!(services)

      refute encoded =~ "gho_super_secret"
      refute encoded =~ "access_token"

      [gmail] = services

      assert Map.keys(gmail) |> Enum.sort() ==
               ~w(connected description identity name status toolkit)a
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp composio_env do
    Application.put_env(:dran, :composio,
      base_url: "https://backend.composio.dev",
      api_key: "test-instance-key",
      timeout: 5_000,
      req_plug: {Req.Test, Dran.Composio}
    )
  end

  defp stub_composio(fun), do: Req.Test.stub(Dran.Composio, fun)

  # El vendor devuelve la lista del PROYECTO entera: las cuentas de los dos
  # lectores. El filtro de dran es lo que está en prueba — por eso el stub sirve
  # las mismas filas a quien pregunte, y exige que la petición declare el lector.
  defp project_stub(conn, alice, bob, unique) do
    params = decode_query(conn)

    case conn.request_path do
      "/api/v3.1/connected_accounts" ->
        # El filtro por lector viaja en la petición (F40)…
        assert [reader] = params["user_ids"]
        assert reader in [to_string(alice.id), to_string(bob.id)]

        # …y la respuesta trae las cuentas del PROYECTO. El filtro sobre la
        # respuesta es el que evita la fuga.
        Req.Test.json(conn, %{
          "items" => [
            account("gmail", alice.id, "ACTIVE", "alice-#{unique}@gmail.com", "ca_alice"),
            account("github", bob.id, "ACTIVE", "bob-#{unique}", "ca_bob"),
            account("gmail", bob.id, "ACTIVE", "bob-#{unique}@gmail.com", "ca_bob_gmail")
          ]
        })

      "/api/v3.1/toolkits" ->
        # La metadata se pide por los slugs de la allowlist, nunca el catálogo
        # entero.
        assert params["toolkit_slugs"] == ["gmail", "github"]

        Req.Test.json(conn, %{
          "items" => [
            %{"slug" => "gmail", "name" => "Gmail", "meta" => %{"description" => "Email"}},
            %{"slug" => "github", "name" => "GitHub"}
          ]
        })
    end
  end

  defp decode_query(conn) do
    case conn.query_string do
      "" -> %{}
      qs -> Plug.Conn.Query.decode(qs)
    end
  end

  defp account(toolkit, user_id, status, display_name, id) do
    %{
      "id" => id,
      "user_id" => to_string(user_id),
      "status" => status,
      "toolkit" => %{"slug" => toolkit},
      "state" => %{"val" => %{"displayName" => display_name}}
    }
  end
end
