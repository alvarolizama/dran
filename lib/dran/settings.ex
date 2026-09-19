defmodule Dran.Settings do
  @moduledoc """
  Runtime settings stored in DB, overriding config defaults.

  `get/1` is served from an ETS cache (one read per key, invalidated on
  `put`/`delete`) because several keys are read on hot paths — search
  (`pagerank_boost`) and the worker loop (`worker_max_pages`, semantic
  thresholds) would otherwise issue a DB query per call.
  """
  alias Dran.Repo
  import Ecto.Query

  @table __MODULE__

  @defaults %{
    "semantic_threshold_short" => 0.15,
    "semantic_threshold_mid" => 0.22,
    "semantic_threshold_long" => 0.28,
    "worker_max_pages" => 10,
    "worker_max_sources" => 10,
    "pagerank_boost" => 0.15,
    "entity_linker_enabled" => true,
    "summary_language" => "auto",
    "wiki_google_open_signup" => false
  }

  def defaults, do: @defaults

  @doc """
  Cached settings table — started by the app supervision tree and by
  `start_supervised!/1` in tests. Public so the supervisor can reference it.
  An Agent owns the table: it exits with the table (no leak between runs)
  and satisfies the child_spec start contract.
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

  def get(key) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> value
      [] -> cache_and_fetch(key)
    end
  end

  defp cache_and_fetch(key) do
    value =
      case Repo.one(from s in "settings", where: s.key == ^key, select: s.value) do
        nil -> Map.get(@defaults, key)
        %{"value" => value} -> value
        value -> value
      end

    # Best effort: tests and any node without the table still work, just
    # uncached.
    :ets.insert_new(@table, {key, value})
    value
  rescue
    # Table missing (e.g. read during boot before the supervisor starts it)
    # or DB down — fall back to the compiled default, never crash a reader.
    _ -> Map.get(@defaults, key)
  end

  def put(key, value) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert_all(
      "settings",
      [%{key: key, value: %{"value" => value}, inserted_at: now, updated_at: now}],
      on_conflict: [set: [value: %{"value" => value}, updated_at: now]],
      conflict_target: :key
    )

    invalidate(key)
  end

  @doc """
  Remove a settings key so its default (or nil) takes effect again.
  """
  def delete(key) do
    Repo.delete_all(from s in "settings", where: s.key == ^key)
    invalidate(key)
  end

  defp invalidate(key) do
    :ets.delete(@table, key)
  rescue
    _ -> :ok
  end

  @doc """
  Drops every cached value. Test support: the SQL sandbox rolls the DB back
  after each test, but this cache survives — DataCase clears it per test so
  no test reads another test's settings.
  """
  def clear_cache do
    :ets.delete_all_objects(@table)
  rescue
    _ -> :ok
  end

  def all do
    db =
      Repo.all(from s in "settings", select: {s.key, s.value})
      |> Map.new(fn {k, v} -> {k, if(is_map(v), do: Map.get(v, "value"), else: v)} end)

    Map.merge(@defaults, db)
  end
end
