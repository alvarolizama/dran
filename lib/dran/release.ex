defmodule Dran.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.

  All public functions are safe to call from a release container:

    * `setup/0`  — create DB (if missing) → migrate → seed. Idempotent.
    * `migrate/0` — run pending migrations.
    * `seed/0`   — run priv/repo/seeds.exs (the seeds script itself is idempotent).
    * `rollback/2` — roll a single repo back to a given version.
  """
  @app :dran

  @doc """
  Idempotent first-run setup: create the database if it does not exist,
  run any pending migrations, and run seeds.

  Safe to invoke on every deploy — it short-circuits when the database
  already exists, and migrations/seeds are themselves idempotent.

  ## Example

      bin/dran eval Dran.Release.setup
  """
  def setup do
    load_app()
    create_if_missing()
    migrate()
    seed()
    :ok
  end

  @doc """
  Create the configured repos' databases. Treats "already exists" as success.
  """
  def create do
    load_app()

    for repo <- repos() do
      case ensure_db_created(repo) do
        :ok -> :ok
        {:error, term} -> raise "failed to create db for #{inspect(repo)}: #{inspect(term)}"
      end
    end
  end

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  def seed do
    load_app()
    run_seeds()
  end

  # --- private ---

  defp create_if_missing do
    for repo <- repos() do
      _ = ensure_db_created(repo)
      :ok
    end
  end

  defp ensure_db_created(repo) do
    case repo.__adapter__.storage_up(repo.config) do
      :ok ->
        IO.puts("[release] created database for #{inspect(repo)}")
        :ok

      {:error, {:already_up, _}} ->
        IO.puts("[release] database already exists for #{inspect(repo)}, skipping create")
        :ok

      {:error, term} ->
        {:error, term}
    end
  end

  defp run_seeds do
    seeds_file = Application.app_dir(@app, "priv/repo/seeds.exs")
    Code.eval_file(seeds_file)
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
