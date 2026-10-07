defmodule Dran.Services.InventoryProbePlug do
  @moduledoc """
  Plug de prueba del vendor: instrumenta y responde.

  Corre en el proceso de la REQUEST, no en el del test (que es donde lo haría
  `Req.Test`): sólo así se puede medir concurrencia de verdad. Si los dos hops
  del inventario viajan en paralelo, el contador de llamadas simultáneas llega
  a 2; si viajan en serie, nunca pasa de 1.
  """

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    agent = Keyword.fetch!(opts, :agent)
    hop = hop(conn)
    delay = opts |> Keyword.get(:delays, %{}) |> Map.get(hop, 0)

    Agent.update(agent, fn state ->
      in_flight = state.in_flight + 1

      state
      |> Map.put(:in_flight, in_flight)
      |> Map.put(:max_in_flight, max(state.max_in_flight, in_flight))
      |> update_in([:calls, hop], &((&1 || 0) + 1))
    end)

    if is_integer(delay) and delay > 0, do: Process.sleep(delay)
    Agent.update(agent, &Map.update!(&1, :in_flight, fn n -> n - 1 end))

    case Keyword.get(opts, :status, %{}) |> Map.get(hop) do
      nil -> respond(conn, hop, opts)
      status -> json(conn, %{"message" => "vendor refused"}, status)
    end
  end

  defp hop(conn) do
    cond do
      String.ends_with?(conn.request_path, "/toolkits") -> :toolkits
      String.ends_with?(conn.request_path, "/connected_accounts") -> :accounts
      true -> :other
    end
  end

  defp respond(conn, :toolkits, opts) do
    slugs = Keyword.get(opts, :catalog_slugs, ["gmail"])

    rows =
      Enum.map(slugs, fn slug ->
        %{
          "slug" => slug,
          "name" => "Catalog #{slug}",
          "meta" => %{"description" => "Catalog description for #{slug}"}
        }
      end)

    json(conn, %{"items" => rows})
  end

  defp respond(conn, :accounts, opts) do
    json(conn, %{"items" => Keyword.get(opts, :accounts, [])})
  end

  defp respond(conn, _hop, _opts), do: json(conn, %{"items" => []})

  defp json(conn, body, status \\ 200) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end
end

defmodule Dran.Services.InventoryLatencyTest do
  @moduledoc """
  La latencia del inventario: dos hops al vendor que NO tienen por qué sumarse.

  La lectura (`GET /api/services`, `list_services/1`) necesita el estado real de
  las conexiones — eso es la autoridad — y, además, la metadata del toolkit para
  ADORNAR cada entrada. Lo segundo es decoración: si el catálogo tarda, la lista
  tiene que salir igual con el slug humanizado, y el nombre no se vuelve a pedir
  nunca más (el catálogo es de la instancia).
  """

  use DranWeb.ConnCase, async: false

  alias Dran.Accounts
  alias Dran.Services
  alias Dran.Services.ToolkitMetaCache

  setup do
    original = Application.get_env(:dran, :composio)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:dran, :composio)
      else
        Application.put_env(:dran, :composio, original)
      end
    end)

    {:ok, user} =
      Accounts.create_user(%{
        email: "inventory-#{System.unique_integer([:positive])}@example.com",
        name: "Inventory Reader"
      })

    agent = start_supervised!({Agent, fn -> %{in_flight: 0, max_in_flight: 0, calls: %{}} end})
    Services.put_allowlist(["gmail"])
    ToolkitMetaCache.clear()

    %{user: user, agent: agent}
  end

  defp stub(agent, opts) do
    Application.put_env(:dran, :composio,
      api_key: "instance-key",
      req_plug: {Dran.Services.InventoryProbePlug, Keyword.put(opts, :agent, agent)}
    )
  end

  defp state(agent), do: Agent.get(agent, & &1)

  test "los dos hops del inventario viajan EN PARALELO", %{user: user, agent: agent} do
    # Con el transporte falso no hay socket: los dos hops duran microsegundos y
    # el solapamiento es invisible. El delay hace observable la ventana — si
    # viajaran en serie, el contador nunca pasaría de 1.
    stub(agent, accounts: [connected_row("gmail")], delays: %{accounts: 150, toolkits: 150})

    assert {:ok, [service]} = Services.list_services(user)

    assert service.name == "Catalog gmail"
    assert service.description == "Catalog description for gmail"
    assert service.connected

    snapshot = state(agent)
    assert snapshot.calls[:accounts] == 1
    assert snapshot.calls[:toolkits] == 1

    # La medición: con los hops en serie el contador nunca pasa de 1.
    assert snapshot.max_in_flight == 2,
           "el inventario tiene que pedir conexiones y catálogo a la vez, no uno tras otro"
  end

  test "la metadata se cachea: la segunda lectura no vuelve a pedir el catálogo",
       %{user: user, agent: agent} do
    stub(agent, accounts: [connected_row("gmail")], delays: %{accounts: 150, toolkits: 150})

    assert {:ok, [first]} = Services.list_services(user)
    assert first.name == "Catalog gmail"

    assert {:ok, [second]} = Services.list_services(user)
    assert second.name == "Catalog gmail"
    assert second.description == "Catalog description for gmail"

    snapshot = state(agent)
    assert snapshot.calls[:accounts] == 2, "el estado real se lee SIEMPRE: no se cachea"
    assert snapshot.calls[:toolkits] == 1, "el nombre del toolkit se pide una sola vez"

    # Y la segunda lectura ya no tiene nada que paralelizar: un hop.
    assert snapshot.max_in_flight == 2
  end

  test "un catálogo LENTO no retiene la lectura ni ensucia el caché", %{user: user, agent: agent} do
    # El catálogo se pasa del presupuesto de la decoración (2s): la lectura
    # sigue, con el nombre humanizado.
    stub(agent, accounts: [connected_row("gmail")], delays: %{toolkits: 5_000})

    started = System.monotonic_time(:millisecond)
    assert {:ok, [service]} = Services.list_services(user)
    elapsed = System.monotonic_time(:millisecond) - started

    assert service.name == "Gmail", "sin catálogo, el nombre sale del slug"
    assert service.description == nil
    assert service.connected, "la autoridad de la lectura (las conexiones) llegó igual"

    assert elapsed < 4_000,
           "la decoración tiene que cortarse en su presupuesto (2s), no esperar al vendor (#{elapsed}ms)"

    assert ToolkitMetaCache.get_many(["gmail"]) == %{},
           "un catálogo que no llegó no se cachea: la próxima lectura reintenta"
  end

  test "un catálogo caído no tumba la lectura y deja reintentar", %{user: user, agent: agent} do
    stub(agent, accounts: [connected_row("gmail")], status: %{toolkits: 500})

    assert {:ok, [service]} = Services.list_services(user)
    assert service.name == "Gmail"
    assert ToolkitMetaCache.get_many(["gmail"]) == %{}
  end

  defp connected_row(toolkit) do
    %{
      "id" => "ca_#{toolkit}",
      "toolkit_slug" => toolkit,
      "status" => "ACTIVE",
      "state" => %{"val" => %{"displayName" => "reader@example.com"}}
    }
  end
end
