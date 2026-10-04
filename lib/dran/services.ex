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
