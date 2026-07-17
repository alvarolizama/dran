defmodule Dran.Chat.Supervisor do
  @moduledoc """
  DynamicSupervisor for `Dran.Chat.Server` processes.

  Each chat conversation runs as a temporary GenServer registered via
  `Dran.ChatRegistry` under a `{context_slug, user}` key. Use
  `find_or_start/2` to get or start a conversation by context slug.

  ## Registry key

  The registry uses the context **slug** (not id) + user as the key,
  because the UI works with slugs. The server itself receives the
  context_id resolved by `find_or_start`.
  """

  use DynamicSupervisor

  @registry Dran.ChatRegistry

  # ── Public API ───────────────────────────────────────────────────────────

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @doc """
  Find a running chat server for (context_slug, user) or start a new one.

  Returns `{:ok, pid}` or `{:error, reason}`.
  """
  @spec find_or_start(String.t(), String.t(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def find_or_start(context_slug, user, opts \\ []) do
    case lookup(context_slug, user) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, :not_found} ->
        start_server(context_slug, user, opts)
    end
  end

  @doc "Look up a running chat server by (context_slug, user)"
  @spec lookup(String.t(), String.t()) :: {:ok, pid()} | {:error, :not_found}
  def lookup(context_slug, user) do
    case Registry.lookup(@registry, {context_slug, user}) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  @doc "Stop a chat server"
  @spec stop(String.t(), String.t()) :: :ok | {:error, :not_found}
  def stop(context_slug, user) do
    case lookup(context_slug, user) do
      {:ok, pid} ->
        DynamicSupervisor.terminate_child(__MODULE__, pid)

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  # ── DynamicSupervisor callback ───────────────────────────────────────────

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  # ── Internal ─────────────────────────────────────────────────────────────

  defp start_server(context_slug, user, opts) do
    context = Dran.Brain.get_context_by_slug(context_slug)

    if is_nil(context) do
      {:error, :context_not_found}
    else
      page_slug = Keyword.get(opts, :page_slug)
      sandbox_owner = Keyword.get(opts, :sandbox_owner)
      via = {:via, Registry, {@registry, {context_slug, user}}}

      start_opts = [
        context_id: context.id,
        user: user,
        page_slug: page_slug,
        sandbox_owner: sandbox_owner,
        name: via
      ]

      case DynamicSupervisor.start_child(__MODULE__, {Dran.Chat.Server, start_opts}) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
