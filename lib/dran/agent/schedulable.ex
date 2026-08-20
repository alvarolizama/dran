defmodule Dran.Agent.Schedulable do
  @moduledoc """
  Shared `run_scheduled/0` for agents triggered by the Quantum scheduler.

  Every scheduled agent iterates over ALL workspaces and starts a
  session for each. This module provides that via `__using__`.

  ## Usage

      defmodule Dran.Agent.Curator do
        use Dran.Agent.Schedulable, input: "scheduled run"

        def run(input, workspace_id, opts \\ []) do
          Dran.Agent.Engine.run(__MODULE__, input, workspace_id, opts)
        end
      end

  The `:input` option sets the session input string used for the scheduled
  run (each agent labels its own cron sessions).
  """

  defmacro __using__(opts) do
    input = Keyword.get(opts, :input, "scheduled run")

    quote do
      @doc """
      Run a scheduled pass on ALL workspaces.

      Iterates every workspace and starts the engine against it.
      """
      def run_scheduled do
        workspaces = Dran.Knowledge.list_workspaces()

        if workspaces == [] do
          {:error, :no_workspaces}
        else
          Enum.map(workspaces, fn ws ->
            run(unquote(input), ws.id)
          end)
        end
      end

      defoverridable run_scheduled: 0
    end
  end
end
