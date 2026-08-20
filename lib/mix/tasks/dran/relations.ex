defmodule Mix.Tasks.Dran.Relations do
  @moduledoc """
  Backfill semantic relations for pages in a context.

  ## Examples

      mix dran.relations personal
      mix dran.relations personal --k 5
  """

  use Mix.Task

  import Ecto.Query

  alias Dran.Repo
  alias Dran.Brain
  alias Dran.Page

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    parsed = OptionParser.parse_head!(args, strict: [k: :integer])
    opts = elem(parsed, 0)
    remaining = elem(parsed, 1)

    slug = List.first(remaining) || raise "context slug is required"

    k = Keyword.get(opts, :k, 3)

    context = Brain.get_workspace_by_slug(slug) || raise "context not found: #{slug}"

    pages =
      Repo.all(
        from p in Page,
          where: p.workspace_id == ^context.id,
          select: p
      )

    total = length(pages)

    pages
    |> Enum.with_index(1)
    |> Enum.each(fn {page, i} ->
      case Brain.auto_relate(page, k: k) do
        {:ok, rels} ->
          Mix.shell().info("[#{i}/#{total}] #{page.slug}: #{length(rels)} semantic relations")

        {:error, reason} ->
          Mix.shell().error("[#{i}/#{total}] #{page.slug}: #{inspect(reason)}")
      end
    end)

    Mix.shell().info("Done.")
  end
end
