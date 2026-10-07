defmodule Dran.Composio.ConfigTest do
  @moduledoc """
  Los presupuestos de la superficie de servicios: defaults, env y el INVARIANTE
  del ladder.

  El invariante cruza los dos artefactos del repo: el cap del CLIENTE (el plugin
  de Hermes, que vive en Python) tiene que quedar por ENCIMA del presupuesto del
  SERVIDOR (`DRAN_COMPOSIO_*`). Invertido, el socket gana la carrera y el agente
  reporta «dran unavailable» sobre un servicio que funciona, sin capa ni
  endpoint ni forma de saber si vale reintentar — el bug que este test caza
  antes de que llegue a un turno. El ladder completo está en el README.

  ExUnit puro: no toca la base.
  """

  use ExUnit.Case, async: false

  alias Dran.Composio.Config

  @plugin Path.expand("../../hermes_plugin/dran/__init__.py", __DIR__)

  setup do
    original = Application.get_env(:dran, :composio)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:dran, :composio)
      else
        Application.put_env(:dran, :composio, original)
      end
    end)

    :ok
  end

  describe "presupuestos del servidor" do
    test "los defaults son los del ladder" do
      Application.delete_env(:dran, :composio)

      assert Config.timeout() == 12_000
      assert Config.execute_timeout() == 25_000
    end

    test "la config de la instancia manda sobre los defaults" do
      Application.put_env(:dran, :composio,
        api_key: "k",
        timeout: 5_000,
        execute_timeout: 9_000
      )

      assert Config.timeout() == 5_000
      assert Config.execute_timeout() == 9_000
    end

    test "sin la key no hay superficie, pero los presupuestos siguen resolviendo" do
      Application.delete_env(:dran, :composio)

      refute Config.enabled?()
      assert is_integer(Config.timeout())
      assert is_integer(Config.execute_timeout())
    end

    test "load_from_env/0 parsea los dos presupuestos" do
      System.put_env("DRAN_COMPOSIO_API_KEY", "k")
      System.put_env("DRAN_COMPOSIO_TIMEOUT", "3000")
      System.put_env("DRAN_COMPOSIO_EXECUTE_TIMEOUT", "4000")

      on_exit(fn ->
        System.delete_env("DRAN_COMPOSIO_API_KEY")
        System.delete_env("DRAN_COMPOSIO_TIMEOUT")
        System.delete_env("DRAN_COMPOSIO_EXECUTE_TIMEOUT")
      end)

      config = Config.load_from_env()

      assert config[:api_key] == "k"
      assert config[:timeout] == 3_000
      assert config[:execute_timeout] == 4_000
    end

    test "un presupuesto basura cae al default" do
      System.put_env("DRAN_COMPOSIO_API_KEY", "k")
      System.put_env("DRAN_COMPOSIO_TIMEOUT", "no-es-un-numero")
      System.put_env("DRAN_COMPOSIO_EXECUTE_TIMEOUT", "-1")

      on_exit(fn ->
        System.delete_env("DRAN_COMPOSIO_API_KEY")
        System.delete_env("DRAN_COMPOSIO_TIMEOUT")
        System.delete_env("DRAN_COMPOSIO_EXECUTE_TIMEOUT")
      end)

      config = Config.load_from_env()

      assert config[:timeout] == 12_000
      assert config[:execute_timeout] == 25_000
    end
  end

  describe "el invariante del ladder" do
    test "el presupuesto del SERVIDOR queda por debajo del cap del CLIENTE" do
      Application.delete_env(:dran, :composio)

      read_cap_ms = plugin_seconds("SERVICES_TIMEOUT_DEFAULT")
      run_cap_ms = plugin_seconds("SERVICES_RUN_TIMEOUT_DEFAULT")

      assert Config.timeout() < read_cap_ms,
             "DRAN_COMPOSIO_TIMEOUT (#{Config.timeout()}ms) tiene que quedar por debajo " <>
               "del cap de lectura del plugin (#{read_cap_ms}ms): el servidor tiene que " <>
               "contestar primero para que un proveedor lento llegue tipado"

      assert Config.execute_timeout() < run_cap_ms,
             "DRAN_COMPOSIO_EXECUTE_TIMEOUT (#{Config.execute_timeout()}ms) tiene que quedar " <>
               "por debajo del cap de ejecución del plugin (#{run_cap_ms}ms)"
    end
  end

  # El cap del cliente, leído del plugin: es el otro lado del contrato y no hay
  # forma de importarlo desde Elixir. Si la constante se renombra, el test falla
  # en vez de pasar en silencio.
  defp plugin_seconds(constant) do
    source = File.read!(@plugin)

    case Regex.run(~r/^#{constant} = ([\d.]+)/m, source) do
      [_, literal] ->
        round(parse_number(literal) * 1000)

      _ ->
        flunk("no encontré #{constant} en el plugin (#{@plugin})")
    end
  end

  defp parse_number(literal) do
    case Float.parse(literal) do
      {value, ""} -> value
      _ -> String.to_integer(literal) * 1.0
    end
  end
end
