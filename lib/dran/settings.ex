defmodule Dran.Settings do
  @moduledoc "Runtime settings stored in DB, overriding config defaults."
  alias Dran.Repo
  import Ecto.Query

  @defaults %{
    "semantic_threshold_short" => 0.15,
    "semantic_threshold_mid" => 0.22,
    "semantic_threshold_long" => 0.28,
    "agent_max_pages" => 10,
    "agent_max_sources" => 10,
    "research_lang" => "es",
    "daily_note_enabled" => true
  }

  def defaults, do: @defaults

  def get(key) do
    case Repo.one(from s in "settings", where: s.key == ^key, select: s.value) do
      nil -> Map.get(@defaults, key)
      %{"value" => value} -> value
      value -> value
    end
  end

  def put(key, value) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    Repo.insert_all("settings", [%{key: key, value: %{"value" => value}, inserted_at: now, updated_at: now}],
      on_conflict: [set: [value: %{"value" => value}, updated_at: now]],
      conflict_target: :key
    )
  end

  def all do
    db = Repo.all(from s in "settings", select: {s.key, s.value})
    |> Map.new(fn {k, v} -> {k, if(is_map(v), do: Map.get(v, "value"), else: v)} end)
    Map.merge(@defaults, db)
  end
end
