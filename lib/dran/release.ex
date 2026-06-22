defmodule Dran.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.

  All public functions are safe to call from a release container:

    * `setup/0`   — create DB (if missing) → migrate → seed. Idempotent.
    * `migrate/0` — run pending migrations.
    * `seed/0`    — run priv/repo/seeds.exs (the seeds script itself is idempotent).
    * `rollback/2` — roll a single repo back to a given version.

  All commands start only the dependencies they need (the Ecto repo and its
  adapter); they intentionally do NOT start the full application supervision
  tree, so the Phoenix endpoint and pubsub stay down during one-off tasks.
  """

  require Logger

  @app :dran
  @start_timeout 30_000

  @doc """
  Idempotent first-run setup: create the database if it does not exist,
  run any pending migrations, and run seeds.

  Safe to invoke on every deploy — it short-circuits when the database
  already exists, and migrations/seeds are themselves idempotent.

  ## Example

      bin/dran eval Dran.Release.setup
  """
  def setup do
    create()
    migrate()
    seed()
    :ok
  end

  @doc """
  Create the configured repos' databases. Treats "already exists" as success.
  """
  def create do
    for repo <- repos() do
      case ensure_db_created(repo) do
        :ok -> :ok
        {:error, term} -> raise "failed to create db for #{inspect(repo)}: #{inspect(term)}"
      end
    end
  end

  @doc """
  Run any pending migrations for every configured repo.
  """
  def migrate do
    load_config()

    for repo <- repos() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true),
          timeout: @start_timeout
        )
    end
  end

  @doc """
  Roll a single repo back to the given version.
  """
  def rollback(repo, version) do
    load_config()

    {:ok, _, _} =
      Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version),
        timeout: @start_timeout
      )
  end

  @doc """
  Run priv/repo/seeds.exs inside an active repo connection.

  The seeds file is expected to use `alias Dran.Repo` and call functions on
  it directly. We use `Ecto.Migrator.with_repo/2` so the repo (and only the
  repo) is started for the duration of the seed run.
  """
  def seed do
    load_config()
    seeds_file = Application.app_dir(@app, "priv/repo/seeds.exs")

    for repo <- repos() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(
          repo,
          fn _repo -> Code.eval_file(seeds_file) end,
          timeout: @start_timeout
        )
    end
  end

  # --- private ---

  defp ensure_db_created(repo) do
    load_config()

    case repo.__adapter__.storage_up(repo.config) do
      :ok ->
        Logger.info("[release] created database for #{inspect(repo)}")
        :ok

      {:error, {:already_up, _}} ->
        Logger.info("[release] database already exists for #{inspect(repo)}, skipping create")
        :ok

      {:error, term} ->
        {:error, term}
    end
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  # Loads config/runtime.exs in :prod (no-op in :dev) and ensures the
  # application module is loaded so its config can be read. Does NOT start
  # the supervision tree, so the Phoenix endpoint stays down.
  defp load_config do
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)

    if config_env() == :prod do
      # In a release, runtime.exs is evaluated at boot by config providers.
      # When `bin/dran eval` runs, the app may not be started yet, so make
      # sure runtime.exs has been evaluated by touching the config.
      _ = Application.get_all_env(@app)
    end

    :ok
  end

  defp config_env do
    case System.get_env("MIX_ENV") do
      nil -> :prod
      env -> String.to_atom(env)
    end
  end
end
