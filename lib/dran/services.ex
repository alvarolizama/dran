defmodule Dran.Services do
  @moduledoc """
  La superficie de SERVICIOS: el plano de control de Composio dentro de dran.

  Tres decisiones que gobiernan todo lo de aquí:

  1. **La identidad es la que ya existe.** El `user_id` que ve Composio sale de
     `identity_for/1`, server-side, y ninguna función acepta un `user_id` o un
     `session_id` de fuera. Una credencial por usuario (`users.api_token`)
     autentica la API, la web y el agente — no hay credencial por agente ni por
     servicio.

     MEDIDO (2026-10-04): `users.id` es `bigint`, no uuid — la premisa «el uuid
     del usuario» del contrato de servicios queda REFUTADA por el árbol.
     `users.actor_id` sí es uuid pero es NULLABLE (los usuarios recién creados,
     y todos los de test, no lo tienen) y una identidad nula en el filtro de
     aislamiento es una fuga fail-open. Se usa la clave primaria local: estable,
     nunca nula, y exactamente lo que el vendor pide («a stable identifier,
     like your database ID, never one that can change»).

  2. **La lista de conexiones es del PROYECTO.** `GET /connected_accounts` sin
     `user_ids` devuelve las cuentas de todos (F40), así que el filtro por el
     lector es parte del contrato de la lectura: se manda a la petición Y se
     vuelve a aplicar sobre la respuesta (defensa en profundidad).

  3. **El estado se LEE, no se cree.** Nada se guarda en la tabla de sesiones
     salvo el puntero del vendor y el snapshot de la allowlist: el ciclo de
     vida (`INITIALIZING → INITIATED → ACTIVE` / `EXPIRED`, `INACTIVE` no
     ejecuta) se consulta al servidor en cada lectura, y los query params de
     vuelta del callback no son prueba de nada (F31).

  El catálogo de la instancia lo decide el owner (allowlist en `Dran.Settings`);
  la conexión es del dueño. Una conexión es autoridad de EJECUCIÓN, no una
  píldora de visibilidad de lectura: no entra en `ContentVisibility` ni en
  `content_shares` — solo el dueño ejecuta contra su conexión.
  """

  alias Dran.Composio
  alias Dran.Repo
  alias Dran.Services.Call
  alias Dran.Services.Session
  alias Dran.Settings

  # Política de instancia: los toolkits que la instancia expone. Lista VACÍA es
  # el default fail-closed (nada expuesto hasta que el owner decida).
  @allowlist_key "service_toolkits"

  # Ciclo de vida de una conexión (F31). El orden es el de "más utilizable
  # primero" y decide qué cuenta gana cuando hay más de una del mismo toolkit.
  @lifecycle_priority ~w(ACTIVE INITIATED INITIALIZING INACTIVE EXPIRED)
  @executable_status "ACTIVE"
  @link_ttl_seconds 600

  @type service :: %{
          toolkit: String.t(),
          name: String.t(),
          description: String.t() | nil,
          connected: boolean(),
          status: String.t() | nil,
          identity: String.t() | nil
        }

  # ── La allowlist de la instancia (política del owner) ──────────────────────

  @doc """
  Los toolkits que la instancia expone, en el orden en que el owner los declaró.

  Acepta una lista o la cadena con comas que guarda la UI de instancia.
  """
  @spec allowlist() :: [String.t()]
  def allowlist do
    Settings.get(@allowlist_key)
    |> normalize_slugs()
  end

  @doc """
  Reescribe la allowlist de la instancia. El owner decide el catálogo: lo que
  no esté aquí no se lista, no se cataloga y no ejecuta.
  """
  @spec put_allowlist([String.t()] | String.t() | nil) :: [String.t()]
  def put_allowlist(slugs) do
    normalized = normalize_slugs(slugs)
    Settings.put(@allowlist_key, normalized)
    normalized
  end

  @spec allowed?(String.t()) :: boolean()
  def allowed?(toolkit) when is_binary(toolkit), do: toolkit in allowlist()

  @doc """
  La integración está encendida cuando la instancia tiene key de Composio.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Composio.enabled?()

  @doc """
  La presencia de la key y la allowlist declarada — lo que `/admin/system`
  muestra como ESTADO (nunca el valor de la clave).
  """
  @spec status() :: map()
  def status do
    %{
      configured: enabled?(),
      toolkits: allowlist(),
      base_url: Composio.Config.base_url()
    }
  end

  @doc """
  Prueba real de la integración para `/admin/system`: sin key es
  `{:error, :not_configured}` sin salir a la red.
  """
  @spec ping() :: {:ok, map()} | {:error, term()}
  def ping do
    if enabled?() do
      Composio.ping()
    else
      {:error, :not_configured}
    end
  end

  # ── Identidad ─────────────────────────────────────────────────────────────

  @doc """
  La identidad estable del lector para Composio: su clave primaria local.

  Nunca viene del cliente y nunca es el email (un email cambia; el vendor pide
  un identificador inmutable).
  """
  @spec identity_for(map() | struct() | integer() | nil) ::
          {:ok, integer()} | {:error, :no_identity}
  def identity_for(id) when is_integer(id), do: {:ok, id}
  def identity_for(%{id: id}) when is_integer(id), do: {:ok, id}
  def identity_for(_), do: {:error, :no_identity}

  @doc """
  El `user_id` tal como viaja a Composio (string) — un solo lugar de traducción.
  """
  @spec composio_user_id(map() | struct() | integer()) ::
          {:ok, String.t()} | {:error, :no_identity}
  def composio_user_id(user) do
    with {:ok, id} <- identity_for(user), do: {:ok, to_string(id)}
  end

  # ── Sesión (una por usuario, reusada) ─────────────────────────────────────

  @doc """
  La sesión del lector: se crea una vez y se reusa.

  Si la allowlist cambió desde que se creó, se reescribe con `PATCH` (enable de
  las nuevas, disable de las que salieron) en lugar de recrearla. Una sesión que
  el vendor ya no conoce (404) se recrea: es un puntero, no una fuente de verdad.
  """
  @spec ensure_session(map() | struct() | integer()) ::
          {:ok, Session.t()} | {:error, term()}
  def ensure_session(user) do
    with {:ok, identity} <- identity_for(user) do
      case Session.get_by_user(identity) do
        nil -> create_session(identity)
        %Session{} = session -> sync_session(session)
      end
    end
  end

  defp create_session(identity) do
    declared = allowlist()

    case Composio.create_session(to_string(identity), declared) do
      {:ok, %{session_id: session_id}} when is_binary(session_id) ->
        Session.upsert(identity, session_id, declared)

      {:ok, _body} ->
        {:error, :no_session_id}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp sync_session(%Session{} = session) do
    declared = allowlist()

    if session.toolkits == declared do
      {:ok, session}
    else
      enable = declared -- session.toolkits
      disable = session.toolkits -- declared

      case Composio.update_session(session.composio_session_id, enable: enable, disable: disable) do
        {:ok, _body} ->
          Session.put_toolkits(session, declared)

        # La sesión ya no existe upstream: el snapshot local es un puntero
        # muerto, se recrea en vez de arrastrarlo.
        {:error, {:composio, 404, _body}} ->
          Repo.delete(session)
          create_session(session.user_id)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Tira la sesión del lector (y su snapshot). Se usa cuando el vendor ya no la
  reconoce; no hay una ruta que borre sesiones a pedido del cliente.
  """
  @spec forget_session(map() | struct() | integer()) :: :ok
  def forget_session(user) do
    with {:ok, identity} <- identity_for(user) do
      case Session.get_by_user(identity) do
        nil -> :ok
        %Session{} = session -> Repo.delete(session)
      end
    end

    :ok
  end

  # ── Conectar / desconectar ────────────────────────────────────────────────
  #
  # El vocabulario es conectar | reconectar | desconectar: no hay pausa (el
  # endpoint del vendor está deprecado) y reconectar NO refresca — emite un link
  # NUEVO (F33/F35).

  @doc """
  El link hospedado para conectar (o reconectar) un servicio.

  Vive 10 minutos (F32): cuando vence se emite otro, nunca se reintenta el
  vencido. El link es de la SESIÓN — el body que sale hacia el vendor lleva
  `{toolkit, callback_url}` y ningún `user_id`, porque la sesión ya es del
  lector.

  La `callback_url` la decide el servidor (`callback_url/0`): una URL de vuelta
  que llega del cliente convierte el retorno del consentimiento en un redirect
  abierto.
  """
  @spec connect_link(map() | struct() | integer(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def connect_link(user, toolkit, callback \\ nil) do
    cond do
      not enabled?() ->
        {:error, :not_configured}

      not allowed?(toolkit) ->
        {:error, :not_allowed}

      true ->
        with {:ok, identity} <- identity_for(user),
             {:ok, session} <- ensure_session(identity),
             {:ok, link} <-
               Composio.link(
                 session.composio_session_id,
                 toolkit,
                 callback || callback_url()
               ),
             {:ok, redirect} <- link_url(link) do
          {:ok, %{toolkit: toolkit, redirect_url: redirect, expires_in: link.expires_in}}
        end
    end
  end

  @doc """
  La URL de vuelta de una conexión: la superficie del usuario en ESTA instancia.

  Una sola, y la fija el servidor. Aceptarla del cliente (o reflejar lo que
  venga en la query) sería un redirect abierto.
  """
  @spec callback_url() :: String.t()
  def callback_url, do: DranWeb.Endpoint.url() <> "/services/callback"

  @doc """
  Desconectar: BORRA la conexión del lector con `revoke_on_delete=true` (F35).

  La revocación upstream es irreversible, así que la advertencia va ANTES en la
  UI. Solo el dueño desconecta: las conexiones que se borran son las que la
  lectura filtró para SU identidad — la conexión de otro no está en la lista, y
  pedirla es un no-op, no un 200 accidental (Q16).
  """
  @spec disconnect(map() | struct() | integer(), String.t()) :: {:ok, map()} | {:error, term()}
  def disconnect(user, toolkit) do
    cond do
      not enabled?() ->
        {:error, :not_configured}

      not allowed?(toolkit) ->
        {:error, :not_allowed}

      true ->
        with {:ok, identity} <- identity_for(user),
             {:ok, accounts} <- connected_accounts_for(identity, [toolkit]) do
          revoke(accounts, toolkit)
        end
    end
  end

  defp revoke([], toolkit), do: {:ok, %{toolkit: toolkit, disconnected: false, revoked: 0}}

  defp revoke(accounts, toolkit) do
    deletable = Enum.filter(accounts, &is_binary(&1["id"]))

    results =
      Enum.map(deletable, fn account ->
        Composio.delete_connected_account(account["id"], revoke: true)
      end)

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil ->
        {:ok, %{toolkit: toolkit, disconnected: deletable != [], revoked: length(deletable)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp link_url(%{redirect_url: url}) when is_binary(url) and url != "", do: {:ok, url}
  defp link_url(_link), do: {:error, :no_link}

  # ── Descubrir ─────────────────────────────────────────────────────────────
  #
  # El catálogo viaja como DATO (F29): unas pocas tools fijas en el cliente y el
  # detalle por toolkit o por caso de uso. Nada de una tool por servicio.

  @doc """
  El catálogo de UN toolkit expuesto: los slugs con su descripción.

  Con `slug` se pide el esquema COMPLETO de esa tool —y solo de esa—: descubrir
  no puede costar cargar el catálogo entero en el contexto (P11).
  """
  @spec catalog(map() | struct() | integer(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def catalog(user, toolkit, opts \\ []) do
    with :ok <- gate(toolkit),
         {:ok, identity} <- identity_for(user),
         {:ok, session} <- ensure_session(identity) do
      slug = opts[:slug]

      filters =
        [toolkit_slugs: [toolkit]] ++ if(slug, do: [tool_slugs: [slug]], else: [])

      case Composio.session_tools(session.composio_session_id, filters) do
        {:ok, tools} ->
          {:ok,
           %{
             toolkit: toolkit,
             slug: slug,
             tools: Enum.map(tools, &tool_entry(&1, toolkit, not is_nil(slug)))
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Búsqueda por CASO DE USO (F29): slugs primarios y relacionados, plan
  recomendado y las trampas conocidas. Es el camino para «quiero mandar un
  mail» sin conocer el slug.
  """
  @spec search(map() | struct() | integer(), String.t()) :: {:ok, map()} | {:error, term()}
  def search(user, use_case) do
    cond do
      not enabled?() ->
        {:error, :not_configured}

      not is_binary(use_case) or String.trim(use_case) == "" ->
        {:error, :missing_query}

      true ->
        with {:ok, identity} <- identity_for(user),
             {:ok, session} <- ensure_session(identity) do
          case Composio.search(session.composio_session_id, use_case) do
            {:ok, body} -> {:ok, normalize_search(use_case, body)}
            {:error, reason} -> {:error, reason}
          end
        end
    end
  end

  # ── Ejecutar ──────────────────────────────────────────────────────────────

  @doc """
  Ejecuta una tool contra la conexión DEL LECTOR.

  Tres gates, en este orden y todos antes de la llamada:

  1. la instancia la expone (allowlist del owner);
  2. la tool viene con nombre;
  3. la conexión está `ACTIVE` — `INACTIVE` no ejecuta y un ciclo a medias
     tampoco.

  Cuando el gate 3 corta, NO se llama al vendor: se devuelve el link de conexión
  (emitido nuevo) para que la web o el agente lo entreguen. Y todo intento queda
  registrado, incluido el que dran cortó (`blocked`).
  """
  @spec execute(
          map() | struct() | integer(),
          String.t() | nil,
          String.t() | nil,
          map(),
          keyword()
        ) ::
          {:ok, map()} | {:error, term()}
  def execute(user, toolkit, tool_slug, arguments, opts \\ []) do
    with :ok <- gate(toolkit),
         :ok <- require_tool(tool_slug),
         {:ok, identity} <- identity_for(user),
         {:ok, status} <- connection_status(identity, toolkit) do
      if executable?(status) do
        run(identity, toolkit, tool_slug, arguments || %{}, opts)
      else
        blocked(user, identity, toolkit, tool_slug, status, opts)
      end
    end
  end

  # ── Helpers de ejecución ──────────────────────────────────────────────────

  defp gate(toolkit) do
    cond do
      not enabled?() -> {:error, :not_configured}
      not allowed?(toolkit) -> {:error, :not_allowed}
      true -> :ok
    end
  end

  defp require_tool(slug) when is_binary(slug) and slug != "", do: :ok
  defp require_tool(_slug), do: {:error, :missing_tool}

  defp connection_status(identity, toolkit) do
    with {:ok, accounts} <- connected_accounts_for(identity, [toolkit]) do
      {:ok, accounts |> best_account() |> then(&(&1 && &1["status"]))}
    end
  end

  defp run(identity, toolkit, tool_slug, arguments, opts) do
    started = System.monotonic_time(:millisecond)

    with {:ok, session} <- ensure_session(identity) do
      result =
        Composio.execute(session.composio_session_id, tool_slug, arguments,
          account: opts[:account]
        )

      elapsed = System.monotonic_time(:millisecond) - started
      audit(identity, toolkit, tool_slug, result, elapsed, opts)

      case result do
        {:ok, body} ->
          {:ok,
           %{
             toolkit: toolkit,
             tool_slug: tool_slug,
             log_id: body["log_id"],
             result: body["data"],
             error: body["error"]
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp blocked(user, identity, toolkit, tool_slug, status, opts) do
    audit(identity, toolkit, tool_slug, {:blocked, status}, 0, opts)

    {:error,
     {:not_connected,
      %{toolkit: toolkit, status: status, connect_url: connect_url_for(user, toolkit)}}}
  end

  # El link vencido no se reintenta: se emite uno NUEVO (F32). Si el proveedor
  # no lo da, se devuelve la superficie de la instancia — nunca un mensaje del
  # vendor como si fuera una instrucción para el usuario.
  defp connect_url_for(user, toolkit) do
    case connect_link(user, toolkit) do
      {:ok, %{redirect_url: url}} -> url
      _ -> callback_url()
    end
  end

  # dran ve cada llamada (F30): una fila por intento, con el resumen truncado y
  # sin credenciales. Best-effort: un registro que falla no deshace la ejecución
  # que ya pasó — se avisa y sigue.
  defp audit(identity, toolkit, tool_slug, result, elapsed, opts) do
    {status, log_id, payload} =
      case result do
        {:ok, body} -> {"ok", body["log_id"], body["data"] || body["error"]}
        {:error, {:composio, _status, body}} -> {"error", log_id_of(body), body}
        {:error, reason} -> {"error", nil, inspect(reason)}
        {:blocked, _status} -> {"blocked", nil, nil}
      end

    attrs = %{
      user_id: identity,
      toolkit: toolkit,
      tool_slug: tool_slug,
      actor: opts[:actor],
      agent_name: opts[:agent_name],
      log_id: log_id,
      status: status,
      result: Call.summarize(payload),
      duration_ms: elapsed
    }

    case Call.record(attrs) do
      {:ok, _call} ->
        :ok

      {:error, changeset} ->
        require Logger
        Logger.warning("service call not recorded: #{inspect(changeset.errors)}")
    end
  end

  defp log_id_of(body) when is_map(body), do: body["log_id"]
  defp log_id_of(_body), do: nil

  defp tool_entry(tool, toolkit, full?) do
    entry = %{
      slug: tool["slug"] || tool["tool_slug"],
      name: tool["name"] || tool["slug"] || tool["tool_slug"],
      toolkit: toolkit,
      description: tool["description"]
    }

    if full? do
      Map.merge(entry, %{
        input_parameters: tool["input_parameters"],
        output_parameters: tool["output_parameters"]
      })
    else
      entry
    end
  end

  defp normalize_search(use_case, body) when is_map(body) do
    result =
      case body["results"] do
        [first | _] when is_map(first) -> first
        _ -> body
      end

    %{
      query: use_case,
      primary_tool_slugs: result["primary_tool_slugs"] || [],
      related_tool_slugs: result["related_tool_slugs"] || [],
      recommended_plan_steps: result["recommended_plan_steps"] || [],
      known_pitfalls: result["known_pitfalls"]
    }
  end

  defp normalize_search(use_case, _body) do
    %{
      query: use_case,
      primary_tool_slugs: [],
      related_tool_slugs: [],
      recommended_plan_steps: [],
      known_pitfalls: nil
    }
  end

  # ── Lectura: el estado real de lo conectado ───────────────────────────────

  @doc """
  Los servicios de la INSTANCIA (allowlist del owner) con el estado real de lo
  que ESTE lector tiene conectado.

  Devuelve todas las entradas de la allowlist, conectadas o no: la sección
  necesita poder ofrecer «conectar» además de mostrar «desconectar». Lo que no
  está en la allowlist no aparece — ni como entrada ni como dato de una conexión
  ajena.
  """
  @spec list_services(map() | struct() | integer()) :: {:ok, [service()]} | {:error, term()}
  def list_services(user) do
    allowed = allowlist()

    cond do
      not enabled?() ->
        {:error, :not_configured}

      allowed == [] ->
        {:ok, []}

      true ->
        with {:ok, identity} <- identity_for(user),
             {:ok, accounts} <- connected_accounts_for(identity, allowed) do
          {:ok, decorate(allowed, accounts)}
        end
    end
  end

  @doc """
  Las conexiones de UN lector, ya filtradas.

  La lista del vendor es del proyecto entero: `user_ids` va en la petición y el
  filtro por lector se aplica otra vez sobre la respuesta.
  """
  @spec connected_accounts_for(integer(), [String.t()]) :: {:ok, list(map())} | {:error, term()}
  def connected_accounts_for(identity, toolkits) do
    with {:ok, rows} <-
           Composio.connected_accounts(
             user_ids: [to_string(identity)],
             toolkit_slugs: toolkits,
             # Sin filtro de estado: un `EXPIRED` o un `INACTIVE` también es
             # estado que el usuario tiene que ver (y el gate de ejecución lo
             # necesita). Filtrarlos aquí los volvería invisibles.
             limit: 100
           ) do
      {:ok, Enum.filter(rows, &mine?(&1, identity, toolkits))}
    end
  end

  defp mine?(account, identity, toolkits) do
    user = account["user_id"] || account["userId"]
    slug = toolkit_of(account)

    (is_nil(user) or to_string(user) == to_string(identity)) and slug in toolkits
  end

  defp decorate(allowed, accounts) do
    meta = toolkit_meta(allowed)
    by_toolkit = group_accounts(accounts)

    Enum.map(allowed, fn slug ->
      account = best_account(Map.get(by_toolkit, slug, []))
      info = Map.get(meta, slug, %{})

      %{
        toolkit: slug,
        name: info[:name] || humanize(slug),
        description: info[:description],
        connected: not is_nil(account),
        status: account && account["status"],
        identity: account && display_name(account)
      }
    end)
  end

  # El nombre es decoración: si el catálogo del vendor no contesta, la lista sale
  # igual con el slug humanizado. Un fallo de metadata no puede tumbar la lectura
  # del estado.
  defp toolkit_meta(slugs) do
    case Composio.toolkits(slugs) do
      {:ok, rows} ->
        Map.new(rows, fn row ->
          slug = row["slug"] || row["toolkit"] || row["name"]

          {slug,
           %{
             name: row["name"] || humanize(slug),
             description: get_in(row, ["meta", "description"]) || row["description"]
           }}
        end)

      {:error, _reason} ->
        %{}
    end
  end

  defp group_accounts(accounts) do
    Enum.group_by(accounts, &toolkit_of/1, & &1)
  end

  defp toolkit_of(account) do
    account["toolkit_slug"] || get_in(account, ["toolkit", "slug"]) ||
      get_in(account, ["toolkit", "name"])
  end

  defp best_account([]), do: nil

  defp best_account(accounts) do
    Enum.min_by(accounts, fn account ->
      Enum.find_index(@lifecycle_priority, &(&1 == account["status"])) ||
        length(@lifecycle_priority)
    end)
  end

  defp display_name(account) do
    get_in(account, ["state", "val", "displayName"]) || account["display_name"] ||
      account["alias"]
  end

  # ── Helpers de presentación ───────────────────────────────────────────────

  @doc """
  El estado de ejecución de una conexión: solo `ACTIVE` ejecuta (F31).
  """
  @spec executable?(String.t() | nil) :: boolean()
  def executable?(status), do: status == @executable_status

  @doc "La vida del link hospedado: 10 minutos, se re-emite, no se reintenta."
  def link_ttl_seconds, do: @link_ttl_seconds

  defp humanize(slug) when is_binary(slug) do
    slug |> String.replace(~r/[_-]+/, " ") |> String.split() |> Enum.map_join(" ", &capitalize/1)
  end

  defp humanize(other), do: to_string(other)

  defp capitalize(word) do
    case String.next_grapheme(word) do
      {first, rest} -> String.upcase(first) <> rest
      nil -> word
    end
  end

  defp normalize_slugs(nil), do: []

  defp normalize_slugs(slugs) when is_binary(slugs) do
    slugs |> String.split(",", trim: true) |> normalize_slugs()
  end

  defp normalize_slugs(slugs) when is_list(slugs) do
    slugs
    |> Enum.map(&normalize_slug/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_slugs(_), do: []

  defp normalize_slug(slug) when is_binary(slug) do
    case slug |> String.trim() |> String.downcase() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_slug(_), do: nil
end
