defmodule Dran.Agent.Schedulable do
  @moduledoc """
  Shared `run_scheduled/0` for agents triggered by the Quantum scheduler.

  Every scheduled agent does the same dance: resolve the default context
  slug via `Dran.Auth.default_context_slug/0`, look it up, and start an
  engine session against it. This module provides that via `__using__`.

  ## Usage

      defmodule Dran.Agent.Curator do
        use Dran.Agent.Schedulable, input: "scheduled run"

        def run(input, context_id, opts \\ []) do
          Dran.Agent.Engine.run(__MODULE__, input, context_id, opts)
        end
      end

  The `:input` option sets the session input string used for the scheduled
  run (each agent labels its own cron sessions).
  """

  defmacro __using__(opts) do
    input = Keyword.get(opts, :input, "scheduled run")

    quote do
      @doc """
      Run a scheduled pass on the default context.

      Resolves the default context slug via `Dran.Auth.default_context_slug/0`,
      looks it up, and starts the engine.
      """
      @spec run_scheduled() :: {:ok, Dran.Agent.Session.t()} | {:error, :context_not_found}
      def run_scheduled do
        slug = Dran.Auth.default_context_slug()

        case Dran.Brain.get_context_by_slug(slug) do
          nil ->
            {:error, :context_not_found}

          ctx ->
            run(unquote(input), ctx.id)
        end
      end

      defoverridable run_scheduled: 0
    end
  end
end
