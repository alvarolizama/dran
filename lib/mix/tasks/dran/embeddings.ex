defmodule Mix.Tasks.Dran.Embeddings do
  @moduledoc """
  Backfill embeddings for existing pages.

  ## Usage

      mix dran.embeddings --context personal

  By default it runs synchronously. Use `--async` to enqueue jobs:

      mix dran.embeddings --context personal --async
  """

  use Mix.Task

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: [context: :string, async: :boolean])

    slug = Keyword.get(opts, :workspace, "personal")
    async? = Keyword.get(opts, :async, false)

    Mix.Task.run("app.start")

    case Dran.Brain.get_workspace_by_slug(slug) do
      nil ->
        Mix.shell().error("Context not found: #{slug}")
        exit({:shutdown, 1})

      context ->
        Mix.shell().info("Backfilling embeddings for context '#{slug}'...")

        {count, failures} = Dran.Embeddings.backfill_pages(context, async: async?)

        Mix.shell().info("Generated embeddings for #{count} page(s).")

        if failures != [] do
          Mix.shell().error("#{length(failures)} failure(s):")

          Enum.each(failures, fn {:error, reason} ->
            Mix.shell().error("  - #{inspect(reason)}")
          end)

          exit({:shutdown, 2})
        end
    end
  end
end
