defmodule Dran.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.

  All public functions are safe to call from a release container:

    * `setup/0`         — create DB (if missing) → migrate → seed default context → production seed → backfill personal workspaces. Idempotent.
    * `migrate/0`       — run pending migrations.
    * `seed/0`          — run priv/repo/seeds_prod.exs (opt-in first owner). Safe on every deploy.
    * `seed_demo/0`     — run priv/repo/seeds.exs (full demo content). Dev/demo only: it refuses to run inside a release.
    * `seed_context/0`  — create the default context only. Safe for prod.
    * `backfill_personal_workspaces/0` — give accounts that lack one their personal workspace. Idempotent.
    * `rollback/2`      — roll a single repo back to a given version.
    * `reset/0`         — DESTRUCTIVE: drop the `public` schema (all data) and run setup/0 again, for a from-scratch onboarding.

  All commands start only the dependencies they need (the Ecto repo and its
  adapter); they intentionally do NOT start the full application supervision
  tree, so the Phoenix endpoint and pubsub stay down during one-off tasks.
  """

  require Logger

  @app :dran
  @start_timeout 30_000

  @doc """
  Idempotent first-run setup: create the database if it does not exist,
  run any pending migrations, seed the default context, run the production seed
  (opt-in first owner) and give accounts without one their personal workspace.

  Safe to invoke on every deploy — it short-circuits when the database
  already exists, and migrations are themselves idempotent.

  ## Example

      bin/dran eval Dran.Release.setup
  """
  def setup do
    create()
    migrate()
    seed_context()
    seed()
    backfill_personal_workspaces()
    :ok
  end

  @doc """
  DESTROY the instance and start over from an empty database.

  Drops the `public` schema — every table, so every workspace (personal
  included) with its content, every user, API key and setting — recreates it
  and runs the normal `setup/0` (create → migrate → seed default context →
  backfill personal workspaces). Extensions (`pg_trgm`, `unaccent`, `pgcrypto`,
  `vector`) live in the same schema and are recreated by the migrations.

  Afterwards the instance is back at `/setup`, the first-run screen that
  creates the owner account, and that account gets its own personal workspace.

  The container entrypoint triggers this with `DRAN_RESET=1` (see
  docker/entrypoint.sh).

  Uploaded files on disk are NOT deleted — they become orphaned blobs, which
  is harmless; deleting them is a separate, deliberate operation.
  """
  def reset do
    Logger.warning(
      "[release] RESET: dropping schema public — ALL instance data (workspaces, " <>
        "pages, memories, users, keys, settings) is destroyed"
    )

    drop_schema()
    setup()

    Logger.warning(
      "[release] RESET done: the instance is empty. Open /setup to create the owner."
    )

    :ok
  end

  @doc """
  Give every account that lacks one a personal workspace.

  Idempotent — safe on every deploy. Covers instances that existed before
  personal workspaces (and any account whose creation-time workspace failed).
  """
  def backfill_personal_workspaces do
    load_config()

    for repo <- repos() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(
          repo,
          fn _repo ->
            case Dran.Accounts.backfill_personal_workspaces() do
              {0, 0} ->
                Logger.info("[release] personal workspaces: nothing to backfill")

              {created, failed} ->
                Logger.info(
                  "[release] personal workspaces backfilled: #{created} created, #{failed} failed"
                )
            end
          end,
          timeout: @start_timeout
        )
    end

    :ok
  end

  # Drops and recreates `public`. Runs inside the repo's own connection (the
  # schema is not something Ecto can express), before any migration so the
  # version table starts empty and every migration re-runs.
  defp drop_schema do
    load_config()

    for repo <- repos() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(
          repo,
          fn _repo ->
            Ecto.Adapters.SQL.query!(repo, "DROP SCHEMA IF EXISTS public CASCADE")
            Ecto.Adapters.SQL.query!(repo, "CREATE SCHEMA public")
          end,
          timeout: @start_timeout
        )
    end
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
  Run the **production seed**, `priv/repo/seeds_prod.exs`, inside an active repo
  connection.

  The file is OPT-IN and idempotent: it creates the instance owner only when
  `DRAN_ADMIN_PASSWORD` is set, and without that variable it creates nothing —
  the first account comes in through `/setup`. `setup/0` calls it on every
  deploy, so it must stay safe against a database that already has data.

  Never point it at `priv/repo/seeds.exs`: that is the development demo dataset
  and it creates content with public passwords. `seed_demo/0` is the only way in
  and it refuses to run inside a release.

  `Ecto.Migrator.with_repo/2` starts the repo (and only the repo) for the
  duration of the run: during `bin/dran eval` the supervision tree is not up.
  """
  def seed do
    eval_seed_file(seeds_file())
  end

  @doc """
  Absolute path of the seed `seed/0` evaluates.

  Public so a test can assert it points at the production seed and not at the
  development one — confusing the two is what sows demo data in production.
  """
  @spec seeds_file() :: String.t()
  def seeds_file, do: Application.app_dir(@app, "priv/repo/seeds_prod.exs")

  @doc """
  Run the **demo** dataset, `priv/repo/seeds.exs`, inside an active repo
  connection.

  Demo content (notes, concepts, relations, accounts with public passwords) is
  for a development instance. It REFUSES to run inside a release: a release has
  no `MIX_ENV` and its config is `:prod`, so there is no legitimate case for
  seeding demo data through it.

      mix run -e 'Dran.Release.seed_demo()'   # dev/test
      bin/dran eval Dran.Release.seed_demo    # raises: it is a release
  """
  def seed_demo do
    if release?() do
      raise "refusing to run the demo seed (priv/repo/seeds.exs) inside a release: " <>
              "use Dran.Release.seed/0 (priv/repo/seeds_prod.exs) instead"
    end

    eval_seed_file(Application.app_dir(@app, "priv/repo/seeds.exs"))
  end

  defp eval_seed_file(path) do
    load_config()

    for repo <- repos() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(
          repo,
          fn _repo -> Code.eval_file(path) end,
          timeout: @start_timeout
        )
    end
  end

  # A release runs with no MIX_ENV, and `bin/dran eval` from an image built with
  # MIX_ENV=prod reports "prod": both are a release. In dev/test the variable is
  # there and the demo seed is allowed.
  defp release?, do: System.get_env("MIX_ENV") in [nil, "prod"]

  @doc """
  Create only the default workspace if it does not exist.

  Skipped unless a default workspace is configured — a workspace flagged as
  default in /admin/workspaces (see
  `Dran.Auth.default_workspace_configured?/0`). A deleted workspace stays
  deleted across deploys when nothing is flagged.

  Safe for production: does not create demo pages, todos, or relations.
  Used by `setup/0` so a fresh prod deploy gets a working context without
  polluting the brain with seed content.
  """
  def seed_context do
    if Dran.Auth.default_workspace_configured?() do
      do_seed_context()
    else
      Logger.info(
        "[release] default workspace not configured in settings, skipping default context seed"
      )

      :ok
    end
  end

  defp do_seed_context do
    load_config()

    for repo <- repos() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(
          repo,
          fn _repo ->
            alias Dran.Repo
            alias Dran.Knowledge
            alias Dran.Workspace

            slug = Dran.Auth.default_workspace_slug()
            name = Dran.Auth.default_workspace_name()

            case Repo.get_by(Workspace, slug: slug) do
              nil ->
                {:ok, ctx} = Knowledge.create_workspace(%{name: name, slug: slug})
                Logger.info("[release] created context: #{ctx.name} (#{ctx.slug})")

              existing ->
                Logger.info(
                  "[release] context already exists: #{existing.name} (#{existing.slug})"
                )
            end
          end,
          timeout: @start_timeout
        )
    end
  end

  # --- private ---

  defp ensure_db_created(repo) do
    load_config()

    case repo.__adapter__().storage_up(repo.config()) do
      :ok ->
        Logger.info("[release] created database for #{inspect(repo)}")
        :ok

      {:error, :already_up} ->
        Logger.info("[release] database already exists for #{inspect(repo)}, skipping create")
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
