defmodule Dran.Embeds.Cache do
  @moduledoc """
  ETS TTL cache for external-embed metadata (oEmbed titles, authors,
  thumbnails).

  Why a cache at all: YouTube and Vimeo publish keyless oEmbed endpoints, so
  the title of a video is one HTTP call away — but the *render* path must
  never make that call. Rendering a page is synchronous, happens inside a
  LiveView diff and on every patched update; a provider timeout there would
  stall the reader. So:

    * the editor warms the cache once, when the embed is inserted
      (`DranWeb.PageEdit`'s `"resolve_embed"` event),
    * the renderer only ever READS (`Dran.Embeds.cached/1`),
    * a miss renders without a title — never a network round-trip.

  Storage follows `Dran.Settings`: an Agent owns the named public table and
  dies with it, reads and writes go straight to ETS from the caller's process
  (no GenServer bottleneck), and every operation is a best-effort no-op when
  the table is missing (boot order, `mix run --no-start`, tests without the
  app) — the cache is an optimization, never a hard dependency.
  """

  @table __MODULE__
  @default_ttl 24 * 60 * 60 * 1000

  @doc """
  Table owner. Started by the supervision tree; `start_supervised!/1` in tests.
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
  Fetch a live entry: `{:ok, value}` or `:miss`. Entries past their TTL read
  as `:miss` (and are dropped lazily).
  """
  def get(key, now \\ now_ms()) do
    case :ets.lookup(@table, key) do
      [{^key, value, expires_at}] when expires_at > now ->
        {:ok, value}

      [{^key, _value, _expires_at}] ->
        delete(key)
        :miss

      [] ->
        :miss
    end
  rescue
    _ -> :miss
  end

  @doc """
  Store `value` under `key` for `ttl` milliseconds.
  """
  def put(key, value, ttl \\ @default_ttl) when is_integer(ttl) do
    :ets.insert(@table, {key, value, now_ms() + ttl})
    :ok
  rescue
    _ -> :ok
  end

  def delete(key) do
    :ets.delete(@table, key)
    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Drop every entry. Test support: the SQL sandbox rolls the DB back between
  tests but this cache survives, and a value cached by one test must not be
  read by another.
  """
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    _ -> :ok
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
