defmodule DranWeb.LoginThrottle do
  @moduledoc """
  Failure-based throttle for password login, with two layers.

  ## Layer 1 — the submitted identifier

  Keyed on the identifier (not the client IP) so it works with no dependency on
  proxy topology, and stops credential stuffing against a specific account. It
  can never lock the instance out; the worst case is a time-boxed lockout of one
  account — the standard account-lockout tradeoff — and a successful login
  clears the counter immediately.

  ## Layer 2 — the client IP

  The IP comes from `conn.remote_ip`, rewritten by `DranWeb.Plugs.ClientIp`
  from `x-forwarded-for`. Its threshold is deliberately HIGHER than the
  identifier's: one address is routinely shared by an office, a VPN or a NAT
  gateway, so a tight cap would lock out a whole network.

  Layer 2 is only as trustworthy as the header: it assumes the reverse proxy
  SETS `x-forwarded-for` and does not pass client-supplied values through. Read
  the trust note in `DranWeb.Plugs.ClientIp` before relying on it.

  ## Semantics

    * Window: 15 minutes, counted from the first failure in the window.
    * Threshold: 10 failures per identifier, 30 per client IP.
    * A successful login clears the IDENTIFIER counter only (an IP is shared by
      other users, so clearing it would erase their history).
    * Unknown and known identifiers count identically, so the throttle does not
      disclose which accounts exist.
  """

  use GenServer

  @table :dran_login_throttle
  @max_failures 10
  @max_failures_per_ip 30
  @window_seconds 900
  @prune_interval_ms 60_000

  @doc "Starts the throttle (owning the ETS table)."
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Whether `identifier` may attempt a login right now.

  Returns `:ok` or `{:error, :throttled}`.
  """
  @spec check(binary() | nil) :: :ok | {:error, :throttled}
  def check(identifier), do: check_key(:identifier, identifier, @max_failures)

  @doc "Whether `ip` may attempt a login right now."
  @spec check_ip(binary() | nil) :: :ok | {:error, :throttled}
  def check_ip(ip), do: check_key(:ip, ip, @max_failures_per_ip)

  @doc "Records one failed attempt for `identifier`."
  @spec record_failure(binary() | nil) :: :ok
  def record_failure(identifier), do: record_key(:identifier, identifier)

  @doc "Records one failed attempt for `ip`."
  @spec record_failure_ip(binary() | nil) :: :ok
  def record_failure_ip(ip), do: record_key(:ip, ip)

  @doc "Clears the identifier counter (called after a successful login)."
  @spec clear(binary() | nil) :: :ok
  def clear(identifier) do
    delete_key(:identifier, identifier)
    :ok
  end

  @doc "Seconds the caller should wait before retrying (0 when not throttled)."
  @spec retry_after(binary() | nil) :: non_neg_integer()
  def retry_after(identifier), do: retry_after_key(:identifier, identifier, @max_failures)

  @doc "Same as `retry_after/1` for the IP layer."
  @spec retry_after_ip(binary() | nil) :: non_neg_integer()
  def retry_after_ip(ip), do: retry_after_key(:ip, ip, @max_failures_per_ip)

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

    for {{_kind, _key} = ets_key, %{first_at: first_at}} <- :ets.tab2list(@table),
        first_at < cutoff do
      :ets.delete(@table, ets_key)
    end

    schedule_prune()
    {:noreply, state}
  end

  # ── Internals ─────────────────────────────────────────────────────────────

  defp schedule_prune, do: Process.send_after(self(), :prune, @prune_interval_ms)

  defp check_key(kind, value, max) do
    case lookup(kind, value) do
      %{count: count, first_at: first_at} when count >= max ->
        if fresh?(first_at), do: {:error, :throttled}, else: :ok

      _ ->
        :ok
    end
  end

  defp record_key(kind, value) do
    key = {kind, normalize(value)}
    now = now_s()

    case lookup(kind, value) do
      %{count: count, first_at: first_at} ->
        if fresh?(first_at) do
          :ets.insert(@table, {key, %{count: count + 1, first_at: first_at}})
        else
          :ets.insert(@table, {key, %{count: 1, first_at: now}})
        end

      nil ->
        :ets.insert(@table, {key, %{count: 1, first_at: now}})
    end

    :ok
  end

  defp delete_key(kind, value) do
    if :ets.whereis(@table) != :undefined, do: :ets.delete(@table, {kind, normalize(value)})
  end

  defp retry_after_key(kind, value, max) do
    case lookup(kind, value) do
      %{count: count, first_at: first_at} when count >= max ->
        if fresh?(first_at), do: max(@window_seconds - (now_s() - first_at), 0), else: 0

      _ ->
        0
    end
  end

  defp lookup(kind, value) do
    if :ets.whereis(@table) == :undefined do
      nil
    else
      case :ets.lookup(@table, {kind, normalize(value)}) do
        [{_key, entry}] -> entry
        [] -> nil
      end
    end
  end

  # Blank/absent values share one bucket — a login form with no username (or a
  # request without a usable address) still cannot be hammered for free.
  defp normalize(nil), do: ""

  defp normalize(value) when is_binary(value) do
    value |> String.trim() |> String.downcase()
  end

  defp normalize(_), do: ""

  defp fresh?(first_at), do: now_s() - first_at < @window_seconds

  defp now_s, do: System.monotonic_time(:second)
end
