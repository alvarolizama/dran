defmodule Mix.Tasks.Dran.Graph.Prune do
  @moduledoc """
  Sweep weak and one-directional `semantic` relations from a context.

  ## Examples

      mix dran.graph.prune personal
      mix dran.graph.prune personal --threshold 0.25
      mix dran.graph.prune personal --prune-only
      mix dran.graph.prune personal --mutual-only
  """

  use Mix.Task

  alias Dran.Brain
  alias Dran.Graph.Maintenance

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {opts, remaining, _} =
      OptionParser.parse(args,
        strict: [threshold: :float, prune_only: :boolean, mutual_only: :boolean]
      )

    slug = List.first(remaining) || raise "context slug is required"

    context = Brain.get_workspace_by_slug(slug) || raise "context not found: #{slug}"

    result =
      cond do
        opts[:prune_only] ->
          pruned = Maintenance.prune_semantic(context.id, opts[:threshold])
          %{pruned: pruned, non_mutual: 0}

        opts[:mutual_only] ->
          non_mutual = Maintenance.filter_mutual(context.id)
          %{pruned: 0, non_mutual: non_mutual}

        true ->
          if opts[:threshold] do
            pruned = Maintenance.prune_semantic(context.id, opts[:threshold])
            non_mutual = Maintenance.filter_mutual(context.id)
            %{pruned: pruned, non_mutual: non_mutual}
          else
            Maintenance.sweep(context.id)
          end
      end

    Mix.shell().info(
      "Sweep done for '#{slug}': " <>
        "#{result.pruned} weak edges pruned, #{result.non_mutual} non-mutual edges removed."
    )
  end
end
