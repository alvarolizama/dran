defmodule Dran.Composio do
  @moduledoc """
  REST client for Composio v3.1 — the ONLY place that talks to the vendor.

  There is no Elixir SDK (F9), so this is a thin `Req` client over the four
  areas the instance key is scoped to: *session management*, *session tool
  execution*, *connected accounts* and *tools/toolkits read*. Nothing here
  knows about users, allowlists or dran's own routes — that policy lives in
  `Dran.Services`.

  ## What it does NOT do

  * It never stores credentials: the vendor redacts provider tokens by design
    (F36), so dran only ever handles `connected_account.id`, `status` and the
    `displayName` of the connected identity.
  * It never calls the connected-account `/link` endpoint (it carries `user_id`
    in the body); connecting goes through the SESSION link, whose body carries
    only `{toolkit, callback_url}` (F5).
  * `link/3` hands back a hosted URL that lives 10 minutes: re-emit a new one,
    never retry an expired link (F32).

  Errors are typed: `{:error, :not_configured}` when the instance has no key and
  `{:error, {:composio, status, body}}` for any non-2xx answer.
  """

  alias Dran.Composio.Config

  @api_prefix "/api/v3.1"

  @type error ::
          {:error, :not_configured}
          | {:error, {:composio, non_neg_integer(), term()}}
          | {:error, term()}
  @type result(t) :: {:ok, t} | error()

  @spec enabled?() :: boolean()
  def enabled?, do: Config.enabled?()

  # ── Session management ─────────────────────────────────────────────────────

  @doc """
  Create the user's tool-router session. `toolkits` is the ENABLED slice of the
  instance allowlist; `user_id` is the stable dran identity (see
  `Dran.Services.identity_for/1`).
  """
  @spec create_session(String.t(), [String.t()]) :: result(map())
  def create_session(user_id, toolkits) when is_binary(user_id) and is_list(toolkits) do
    body = %{
      "user_id" => user_id,
      "toolkits" => %{"enable" => toolkits}
    }

    case request(:post, "#{@api_prefix}/tool_router/session", json: body) do
      {:ok, body} -> {:ok, %{session_id: body["session_id"], raw: body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec get_session(String.t()) :: result(map())
  def get_session(session_id) do
    request(:get, "#{@api_prefix}/tool_router/session/#{session_id}")
  end

  @doc """
  Rewrite what the session exposes. The enabled list IS the allowlist slice, so
  a toolkit the owner removed must be explicitly disabled.
  """
  @spec update_session(String.t(), keyword()) :: result(map())
  def update_session(session_id, opts) do
    toolkits =
      %{}
      |> maybe_put("enable", opts[:enable])
      |> maybe_put("disable", opts[:disable])

    body = %{"toolkits" => toolkits}

    request(:patch, "#{@api_prefix}/tool_router/session/#{session_id}", json: body)
  end

  @spec delete_session(String.t()) :: result(term())
  def delete_session(session_id) do
    request(:delete, "#{@api_prefix}/tool_router/session/#{session_id}")
  end

  # ── Connection (hosted link) ───────────────────────────────────────────────

  @doc """
  Ask for a hosted connect link for one toolkit inside the session.

  The body carries `{toolkit, callback_url}` and NOTHING else — in particular
  no `user_id`: the session already belongs to the reader.
  """
  @spec link(String.t(), String.t(), String.t()) :: result(map())
  def link(session_id, toolkit, callback_url) do
    case request(:post, "#{@api_prefix}/tool_router/session/#{session_id}/link",
           json: %{"toolkit" => toolkit, "callback_url" => callback_url}
         ) do
      {:ok, body} ->
        {:ok,
         %{
           redirect_url: body["redirect_url"],
           link_token: body["link_token"],
           expires_in: expires_in(body)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  The toolkits the session exposes, with their connection state (F6).
  """
  @spec session_toolkits(String.t(), keyword()) :: result(list(map()))
  def session_toolkits(session_id, opts \\ []) do
    params =
      list_params(
        toolkit_slugs: opts[:toolkit_slugs],
        is_connected: opts[:is_connected]
      )

    with {:ok, body} <-
           request(:get, "#{@api_prefix}/tool_router/session/#{session_id}/toolkits",
             params: params
           ) do
      {:ok, items(body)}
    end
  end

  # ── Discovery ──────────────────────────────────────────────────────────────

  @doc """
  Tool schemas exposed by the session. `opts` filters by `toolkit_slugs` and/or
  `tool_slugs` — the catalog is DATA, so nothing here grows as toolkits are
  added.
  """
  @spec session_tools(String.t(), keyword()) :: result(list(map()))
  def session_tools(session_id, opts \\ []) do
    params =
      list_params(
        toolkit_slugs: opts[:toolkit_slugs],
        tool_slugs: opts[:tool_slugs],
        limit: opts[:limit]
      )

    with {:ok, body} <-
           request(:get, "#{@api_prefix}/tool_router/session/#{session_id}/tools", params: params) do
      {:ok, items(body)}
    end
  end

  @doc """
  Use-case search over the session's catalog (F29): returns primary/related
  tool slugs, recommended plan steps and known pitfalls.
  """
  @spec search(String.t(), String.t()) :: result(map())
  def search(session_id, use_case) do
    request(:post, "#{@api_prefix}/tool_router/session/#{session_id}/search",
      json: %{"queries" => [%{"use_case" => use_case}]}
    )
  end

  # ── Execution ──────────────────────────────────────────────────────────────

  @doc """
  Execute one tool in the session. dran is in the middle of every call (F30),
  which is exactly why the gate and the log are possible.
  """
  @spec execute(String.t(), String.t(), map(), keyword()) :: result(map())
  def execute(session_id, tool_slug, arguments, opts \\ []) do
    body =
      %{"tool_slug" => tool_slug, "arguments" => arguments || %{}}
      |> maybe_put("account", opts[:account])

    request(:post, "#{@api_prefix}/tool_router/session/#{session_id}/execute", json: body)
  end

  # ── Connected accounts ─────────────────────────────────────────────────────

  @doc """
  The PROJECT-wide list of connections. `user_ids` is mandatory in practice:
  without it the vendor answers with every user's accounts (F40) — the caller
  (`Dran.Services`) always passes the reader's identity.
  """
  @spec connected_accounts(keyword()) :: result(list(map()))
  def connected_accounts(opts \\ []) do
    params =
      list_params(
        user_ids: opts[:user_ids],
        toolkit_slugs: opts[:toolkit_slugs],
        statuses: opts[:statuses],
        limit: opts[:limit] || 100
      )

    with {:ok, body} <- request(:get, "#{@api_prefix}/connected_accounts", params: params) do
      {:ok, items(body)}
    end
  end

  @doc """
  Delete a connection. `revoke_on_delete=true` also revokes upstream (F35) —
  irreversible, so the caller warns before calling.
  """
  @spec delete_connected_account(String.t(), keyword()) :: result(map())
  def delete_connected_account(id, opts \\ []) do
    params = if Keyword.get(opts, :revoke, true), do: %{"revoke_on_delete" => "true"}, else: %{}

    request(:delete, "#{@api_prefix}/connected_accounts/#{id}", params: params)
  end

  @doc """
  Toolkit metadata (name/description) for the slugs named. Used to decorate the
  allowlist; a failure here must never take a read down.
  """
  @spec toolkits([String.t()]) :: result(list(map()))
  def toolkits(slugs \\ []) do
    params = list_params(toolkit_slugs: slugs)

    with {:ok, body} <- request(:get, "#{@api_prefix}/toolkits", params: params) do
      {:ok, items(body)}
    end
  end

  @doc """
  Health-check de la integración: prueba que la key SCOPED de la instancia
  responde. Usa la lectura más barata de su alcance (una página de connected
  accounts), no un catálogo entero.

  Devuelve `{:ok, %{latency_ms: n, accounts: n}}` o el error tipado. Alimenta el
  botón «Probar conexión» de `/admin/system`.
  """
  @spec ping() :: {:ok, %{latency_ms: non_neg_integer(), accounts: non_neg_integer()}} | error()
  def ping do
    start = System.monotonic_time(:millisecond)

    case request(:get, "#{@api_prefix}/connected_accounts", params: [{"limit", "1"}]) do
      {:ok, body} ->
        {:ok,
         %{
           latency_ms: System.monotonic_time(:millisecond) - start,
           accounts: length(items(body))
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Transport ──────────────────────────────────────────────────────────────

  @doc false
  @spec request(atom(), String.t(), keyword()) :: result(term())
  def request(method, path, opts \\ []) do
    if Config.enabled?() do
      req_opts = [
        method: method,
        url: Config.base_url() <> path,
        # The scoped project key is the ONLY credential here — never in a URL,
        # a payload or a log.
        headers: [{"x-api-key", Config.api_key()}],
        receive_timeout: Config.timeout(),
        retry: false
      ]

      req_opts =
        case Config.req_plug() do
          nil -> req_opts
          plug -> Keyword.put(req_opts, :plug, plug)
        end

      req = Req.new(req_opts) |> Req.merge(opts)

      case Req.request(req) do
        {:ok, %{status: status, body: body}} when status in 200..299 ->
          {:ok, body}

        {:ok, %{status: status, body: body}} ->
          {:error, {:composio, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :not_configured}
    end
  end

  defp items(body) when is_map(body), do: body["items"] || []
  defp items(body) when is_list(body), do: body
  defp items(_), do: []

  # Los filtros de la API v3.1 son listas (`user_ids[]=1&toolkit_slugs[]=gmail`)
  # y `URI.encode_query/1` no sabe serializar listas: se expanden aquí, en un
  # solo lugar, para que ningún call site tenga que acordarse.
  defp list_params(entries) do
    entries
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == [] end)
    |> Enum.flat_map(fn
      {key, values} when is_list(values) -> Enum.map(values, &{"#{key}[]", to_string(&1)})
      {key, value} -> [{to_string(key), to_string(value)}]
    end)
  end

  defp expires_in(body) when is_map(body) do
    body["expires_in"] || body["expires_in_seconds"] || 600
  end

  defp expires_in(_), do: 600

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
