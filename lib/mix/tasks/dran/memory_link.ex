defmodule Mix.Tasks.Dran.Memory.Link do
  @moduledoc """
  Backfill `informs` relations (memory → page) for existing memories.

  New memories link automatically at ingest (`Dran.MemoryLinker`); this task
  covers everything stored before that. Idempotent and resumable — existing
  relations are skipped by the unique constraint.

  ## Examples

      mix dran.memory.link personal
      mix dran.memory.link
  """

  use Mix.Task

  alias Dran.Knowledge
  alias Dran.MemoryLinker

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {_, remaining, _} = OptionParser.parse(args, strict: [])

    result =
      case List.first(remaining) do
        nil ->
          MemoryLinker.backfill()

        slug ->
          context = Knowledge.get_workspace_by_slug(slug) || raise "context not found: #{slug}"
          MemoryLinker.backfill(context.id)
      end

    IO.inspect(result, label: "memories linked (seen, created)")
  end
end
