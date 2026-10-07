defmodule Dran.Services.ToolkitMetaCache do
  @moduledoc """
  ETS TTL cache de la metadata de toolkits (nombre y descripción).

  Por qué existe: la lectura del inventario (`Dran.Services.list_services/1`) le
  pide al vendor las conexiones del lector y, además, la metadata para PODER
  ADORNAR cada entrada con el nombre real del servicio. Lo segundo es
  decoración: si el catálogo del vendor tarda, la lista tiene que salir igual
  con el slug humanizado — pero mientras tanto la lectura pagaba DOS hops
  secuenciales, y su latencia era la suma en vez del máximo.

  El catálogo es de la INSTANCIA (el mismo para todos los lectores) y cambia
  casi nunca, así que se cachea por slug con un TTL largo: la primera lectura
  paga el hop, las siguientes no lo pagan y el `Task.async_stream` de la
  lectura deja de tener nada que paralelizar.

  Storage igual que `Dran.Embeds.Cache` y `Dran.Settings`: un Agent dueño de la
  tabla pública con nombre, que muere con ella; lecturas y escrituras van
  directo a ETS desde el proceso que llama (sin cuello de botella) y toda
  operación es un no-op best-effort si la tabla no existe (orden de arranque,
  `mix run --no-start`, tests sin la app). El caché es una optimización, nunca
  una dependencia dura.
  """

  @table __MODULE__
  # La metadata es del VENDOR y de la instancia: nombre y descripción de un
  # toolkit. Seis horas es holgadamente menos de lo que tarda en cambiar y más
  # que cualquier sesión de trabajo.
  @default_ttl 6 * 60 * 60 * 1000

  @doc """
  Dueño de la tabla. Lo arranca el árbol de supervisión; en tests,
  `start_supervised!/1`.
  """
  def child_spec(_arg) do
    %{
      id: __MODULE__,
      start:
        {Agent, :start_link,
         [fn -> :ets.new(@table, [:named_table, :set, :public, read_concurrency: true]) end]},
      restart: :temporary
    }
  end

  @doc """
  Las entradas VIVAS de los slugs pedidos, como mapa `slug => metadata`.

  Devuelve sólo lo que está en el caché: lo que falta lo decide el llamador
  (y el llamador decide con qué presupuesto lo va a buscar).
  """
  @spec get_many([String.t()], integer()) :: %{optional(String.t()) => map()}
  def get_many(slugs, now \\ now_ms()) when is_list(slugs) do
    entries =
      slugs
      |> Enum.map(&:ets.lookup(@table, &1))
      |> List.flatten()

    for {slug, meta, expires_at} <- entries, expires_at > now, into: %{} do
      {slug, meta}
    end
  rescue
    _ -> %{}
  end

  @doc """
  Guarda la metadata de cada slug por `ttl` milisegundos.
  """
  @spec put_many(%{optional(String.t()) => map()}, integer()) :: :ok
  def put_many(meta_by_slug, ttl \\ @default_ttl) when is_map(meta_by_slug) and is_integer(ttl) do
    expires_at = now_ms() + ttl

    Enum.each(meta_by_slug, fn
      {slug, meta} when is_binary(slug) and is_map(meta) ->
        :ets.insert(@table, {slug, meta, expires_at})

      _other ->
        :ok
    end)

    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Vacía el caché. Soporte de test: el sandbox revierte la base entre tests pero
  esta tabla sobrevive, y una entrada cacheada por un test no puede leerse en
  otro (mismo trato que `Dran.Embeds.Cache.clear/0`).
  """
  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    _ -> :ok
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
