defmodule Dran.ServicesExecuteTest do
  @moduledoc """
  Gate de la W4: descubrir y ejecutar con registro y fail-closed.

  Dos reglas que este archivo defiende:

  * **El gate del estado va en el contexto, antes de la llamada.** Sin conexión
    `ACTIVE` no se llama al vendor: se devuelve el link de conexión (emitido
    nuevo) y el intento queda registrado como `blocked`.
  * **dran ve cada llamada.** Una fila por intento con `tool_slug`, actor,
    `agent_name`, `log_id` y toolkit — y sin credenciales: lo que el vendor
    redacta, acá se descarta por nombre de campo.
  """

  use DranWeb.ConnCase, async: false

  alias Dran.Accounts
  alias Dran.Composio
  alias Dran.Repo
  alias Dran.Services
  alias Dran.Services.Call

  import Ecto.Query

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

    Application.put_env(:dran, :composio,
      base_url: "https://backend.composio.dev",
      api_key: "test-instance-key",
      timeout: 5_000,
      req_plug: {Req.Test, Dran.Composio}
    )

    Services.put_allowlist(["gmail"])

    %{alice: alice, unique: unique}
  end

  # ── P12: fail-closed con el link, no con el error del vendor ───────────────

  describe "execute/5 sin conexión ACTIVE" do
    test "no llama al vendor, devuelve un link NUEVO y lo registra como blocked",
         %{alice: alice} do
      stub_composio(%{accounts: [account("gmail", alice.id, "INITIATED", "alice@gmail.com")]})

      assert {:error, {:not_connected, info}} =
               Services.execute(alice, "gmail", "GMAIL_SEND_EMAIL", %{"to" => "x@y.z"},
                 actor: "agent:test",
                 agent_name: "hermes-test"
               )

      assert info.toolkit == "gmail"
      assert info.status == "INITIATED"
      # El link lo emite dran (nuevo), no se repite el error del proveedor.
      assert info.connect_url == "https://app.composio.dev/link/abc"

      # El vendor NO ejecutó nada…
      refute_received {:composio, "POST", "/api/v3.1/tool_router/session/trs_test/execute", _, _}

      # …y el intento que dran cortó queda escrito.
      [call] = calls(alice)
      assert call.status == "blocked"
      assert call.tool_slug == "GMAIL_SEND_EMAIL"
      assert call.toolkit == "gmail"
      assert call.actor == "agent:test"
      assert call.agent_name == "hermes-test"
      assert is_nil(call.log_id)
    end

    test "un estado INACTIVE tampoco ejecuta", %{alice: alice} do
      stub_composio(%{accounts: [account("gmail", alice.id, "INACTIVE", "alice@gmail.com")]})

      assert {:error, {:not_connected, %{status: "INACTIVE"}}} =
               Services.execute(alice, "gmail", "GMAIL_SEND_EMAIL", %{})

      refute_received {:composio, "POST", "/api/v3.1/tool_router/session/trs_test/execute", _, _}
    end

    test "un toolkit fuera de la allowlist no ejecuta ni lista", %{alice: alice} do
      stub_composio(%{accounts: [account("slack", alice.id, "ACTIVE", "alice")]})

      assert {:error, :not_allowed} = Services.execute(alice, "slack", "SLACK_SEND", %{})
      assert {:error, :not_allowed} = Services.catalog(alice, "slack")

      refute_receive {:composio, _, _, _, _}
    end

    test "sin tool_slug no se llama al vendor", %{alice: alice} do
      stub_composio(%{accounts: [account("gmail", alice.id, "ACTIVE", "alice@gmail.com")]})

      assert {:error, :missing_tool} = Services.execute(alice, "gmail", nil, %{})
      refute_receive {:composio, _, _, _, _}
    end
  end

  # ── P12: el registro de la ejecución ───────────────────────────────────────

  describe "execute/5 con la conexión ACTIVE" do
    setup %{alice: alice} do
      stub_composio(%{accounts: [account("gmail", alice.id, "ACTIVE", "alice@gmail.com")]})
      :ok
    end

    test "registra la llamada con su log_id y sin credenciales", %{alice: alice} do
      assert {:ok, result} =
               Services.execute(
                 alice,
                 "gmail",
                 "GMAIL_SEND_EMAIL",
                 %{"to" => "x@y.z"},
                 actor: "account:1",
                 agent_name: "hermes-test"
               )

      assert result.tool_slug == "GMAIL_SEND_EMAIL"
      assert result.log_id == "log_123"
      assert result.result == %{"ok" => true}

      assert_receive {:composio, "POST", "/api/v3.1/tool_router/session/trs_test/execute", _,
                      %{"tool_slug" => "GMAIL_SEND_EMAIL", "arguments" => %{"to" => "x@y.z"}}}

      [call] = calls(alice)
      assert call.user_id == alice.id
      assert call.toolkit == "gmail"
      assert call.tool_slug == "GMAIL_SEND_EMAIL"
      assert call.actor == "account:1"
      assert call.agent_name == "hermes-test"
      assert call.log_id == "log_123"
      assert call.status == "ok"
      # El resumen se guarda, truncado y sin nada con pinta de credencial.
      assert call.result =~ "ok"
      refute call.result =~ "gho_"
      assert is_integer(call.duration_ms)
    end

    test "el resumen descarta campos con pinta de credencial", %{alice: alice} do
      Req.Test.stub(Composio, fn conn ->
        case conn.request_path do
          "/api/v3.1/connected_accounts" ->
            Req.Test.json(conn, %{
              "items" => [account("gmail", alice.id, "ACTIVE", "alice@gmail.com")]
            })

          "/api/v3.1/tool_router/session" ->
            Req.Test.json(conn, %{"session_id" => "trs_test"})

          "/api/v3.1/tool_router/session/trs_test/execute" ->
            Req.Test.json(conn, %{
              "log_id" => "log_456",
              "data" => %{"ok" => true, "access_token" => "gho_super_secret"}
            })
        end
      end)

      assert {:ok, _} = Services.execute(alice, "gmail", "GMAIL_GET_PROFILE", %{})

      [call] = calls(alice)
      assert call.result =~ "[redacted]"
      refute call.result =~ "gho_super_secret"
    end

    test "un error del proveedor también queda registrado", %{alice: alice} do
      Req.Test.stub(Composio, fn conn ->
        case conn.request_path do
          "/api/v3.1/connected_accounts" ->
            Req.Test.json(conn, %{
              "items" => [account("gmail", alice.id, "ACTIVE", "alice@gmail.com")]
            })

          "/api/v3.1/tool_router/session" ->
            Req.Test.json(conn, %{"session_id" => "trs_test"})

          "/api/v3.1/tool_router/session/trs_test/execute" ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.resp(400, Jason.encode!(%{"message" => "bad arguments"}))
        end
      end)

      assert {:error, {:composio, 400, _body}} =
               Services.execute(alice, "gmail", "GMAIL_SEND_EMAIL", %{})

      [call] = calls(alice)
      assert call.status == "error"
      assert call.result =~ "bad arguments"
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp calls(user) do
    Repo.all(
      from c in Call,
        where: c.user_id == ^user.id,
        order_by: [desc: c.inserted_at]
    )
  end

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

        {"GET", "/api/v3.1/tool_router/session/trs_test/tools"} ->
          Req.Test.json(conn, %{
            "items" => [
              %{
                "slug" => "GMAIL_SEND_EMAIL",
                "name" => "Send email",
                "toolkit" => %{"slug" => "gmail"},
                "description" => "Send an email",
                "input_parameters" => %{"to" => %{"type" => "string", "required" => true}},
                "output_parameters" => %{"id" => %{"type" => "string"}}
              }
            ]
          })

        {"POST", "/api/v3.1/tool_router/session/trs_test/search"} ->
          Req.Test.json(conn, %{
            "results" => [
              %{
                "use_case" => "send an email",
                "primary_tool_slugs" => ["GMAIL_SEND_EMAIL"],
                "related_tool_slugs" => ["GMAIL_CREATE_DRAFT"],
                "recommended_plan_steps" => ["Attach the file"],
                "known_pitfalls" => "Attachments must be uploaded first"
              }
            ]
          })

        {"POST", "/api/v3.1/tool_router/session/trs_test/execute"} ->
          Req.Test.json(conn, %{
            "log_id" => "log_123",
            "data" => %{"ok" => true}
          })

        {"GET", "/api/v3.1/toolkits"} ->
          Req.Test.json(conn, %{"items" => []})
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
