defmodule DranWeb.LoginThrottle do
  @moduledoc """
  Failure-based throttle for password login, keyed on the SUBMITTED identifier.

  ## Why the identifier and not the client IP

  Production runs behind a TLS-terminating reverse proxy (`force_ssl` with
  `rewrite_on: [:x_forwarded_proto]`) and the endpoint does not derive the real
  client address from `X-Forwarded-For`, so `conn.remote_ip` is the PROXY's
  address for every request. An IP-keyed limiter would therefore share a single
  counter across all clients: it would neither slow one attacker down nor stop
  a single actor from locking login out for the whole instance.

  Keying on the submitted identifier stops credential stuffing against a
  specific account with no dependency on proxy topology. It can never lock the
  instance out; the worst case is a time-boxed lockout of one account — the
  standard account-lockout tradeoff — and a successful login clears the counter
  immediately.

  A per-IP layer is still missing. Doing it correctly needs the deployment's
  trusted-proxy addresses (a `RemoteIp`-style plug); keying on the raw
  `remote_ip` without that would be either shared or client-spoofable.

  ## Semantics

    * Window: 15 minutes, counted from the first failure.
    * Threshold: 10 failures for the same identifier.
    * A successful login clears the identifier's counter.
    * Unknown and known identifiers are counted identically, so the throttle
      does not disclose which accounts exist.
  """

  use GenServer

  @table :dran_login_throttle
  @max_failures 10
  @window_seconds 900
  @prune_interval_ms 60_000

  @doc "Starts the throttle (owning the ETS table)."
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Whether `identifier` may attempt a login right now.

  Returns `:ok` or `{:error, :throttled}`.
  """
  @spec check(binary() | nil) :: :ok | {:error, :throttled}
  def check(identifier) do
    case lookup(identifier) do
      %{count: count, first_at: first_at} when count >= @max_failures ->
        if fresh?(first_at), do: {:error, :throttled}, else: :ok

      _ ->
        :ok
    end
  end

  @doc "Records one failed attempt for `identifier`."
  @spec record_failure(binary() | nil) :: :ok
  def record_failure(identifier) do
    key = normalize(identifier)
    now = now_s()

    case lookup(key) do
      %{count: count, first_at: first_at} ->
        if fresh?(first_at) do
          put(key, %{count: count + 1, first_at: first_at})
        else
          put(key, %{count: 1, first_at: now})
        end

      nil ->
        put(key, %{count: 1, first_at: now})
    end

    :ok
  end

  @doc "Clears the counter for `identifier` (called after a successful login)."
  @spec clear(binary() | nil) :: :ok
  def clear(identifier) do
    if :ets.whereis(@table) != :undefined, do: :ets.delete(@table, normalize(identifier))
    :ok
  end

  @doc "Seconds the caller should wait before retrying (0 when not throttled)."
  @spec retry_after(binary() | nil) :: non_neg_integer()
  def retry_after(identifier) do
    case lookup(identifier) do
      %{count: count, first_at: first_at} when count >= @max_failures ->
        if fresh?(first_at), do: max(@window_seconds - (now_s() - first_at), 0), else: 0

      _ ->
        0
    end
  end

  @doc "Test helper: drops every counter."
  @spec reset() :: :ok
  def reset do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    :ok
  end

  # ── GenServer ─────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    table =
      :ets.new(@table, [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])

    schedule_prune()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_info(:prune, state) do
    cutoff = now_s() - @window_seconds

    for {key, %{first_at: first_at}} <- :ets.tab2list(@table), first_at < cutoff do
      :ets.delete(@table, key)
    end

    schedule_prune()
    {:noreply, state}
  end

  # ── Internals ─────────────────────────────────────────────────────────────

  defp schedule_prune, do: Process.send_after(self(), :prune, @prune_interval_ms)

  defp lookup(identifier) do
    if :ets.whereis(@table) == :undefined do
      nil
    else
      case :ets.lookup(@table, normalize(identifier)) do
        [{_key, entry}] -> entry
        [] -> nil
      end
    end
  end

  defp put(key, entry), do: :ets.insert(@table, {key, entry})

  # Blank/absent identifiers share one bucket — a login form with no username
  # still cannot be hammered for free.
  defp normalize(nil), do: ""

  defp normalize(identifier) when is_binary(identifier) do
    identifier |> String.trim() |> String.downcase()
  end

  defp normalize(_), do: ""

  defp fresh?(first_at), do: now_s() - first_at < @window_seconds

  defp now_s, do: System.monotonic_time(:second)
end
