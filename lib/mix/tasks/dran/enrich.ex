defmodule Mix.Tasks.Dran.Enrich do
  @moduledoc """
  Enrich pages with web-sourced content using Firecrawl + LLM.

  ## Usage

      mix dran.enrich --context personal
      mix dran.enrich --context personal --slug some-page-slug
      mix dran.enrich --context personal --tags  # create stubs for missing tag pages
      mix dran.enrich --context personal --stubs-only  # only create stubs, don't enrich existing

  ## Options

    * `--context` (required) — context slug to enrich
    * `--slug` — enrich only this specific page
    * `--tags` — also create stub pages for tags without pages
    * `--stubs-only` — only create stubs, skip page enrichment
    * `--limit` — max pages to enrich (default 50)
  """

  use Mix.Task

  alias Dran.{Brain, TagEnricher}

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [
      context: :string,
      slug: :string,
      tags: :boolean,
      stubs_only: :boolean,
      limit: :integer
    ])

    context_slug = opts[:context] || raise "--context is required"
    limit = opts[:limit] || 50

    Mix.Task.run("app.start", [])

    context = Brain.get_context_by_slug(context_slug)

    unless context do
      raise "Context '#{context_slug}' not found"
    end

    if opts[:tags] or opts[:stubs_only] do
      create_stubs(context, limit)
    end

    unless opts[:stubs_only] do
      enrich_pages(context, opts[:slug], limit)
    end
  end

  defp create_stubs(context, limit) do
    Mix.shell().info("Creating stub pages for missing tags in '#{context.slug}'...")

    pages = Brain.list_pages(context_id: context.id, limit: limit)

    for page <- pages do
      tags = page.tags || []
      missing = Enum.filter(tags, &(not tag_has_page?(&1, context.id)))

      for tag <- missing do
        Mix.shell().info("  Creating stub for tag: #{tag}")
        {:ok, created} = TagEnricher.enrich_tags(%{page | tags: [tag]})
        length(created)
      end
      |> Enum.sum()
    end
    |> Enum.sum()
    |> then(fn count ->
      Mix.shell().info("Created #{count} stub pages.")
    end)
  end

  defp enrich_pages(context, nil, limit) do
    Mix.shell().info("Enriching pages in '#{context.slug}'...")

    pages = Brain.list_pages(context_id: context.id, limit: limit)

    for page <- pages do
      body_len = String.length(page.body || "")

      if body_len < 500 do
        Mix.shell().info("  Enriching: #{page.slug} (body: #{body_len} chars)")
        case TagEnricher.enrich_page(page) do
          {:ok, _} -> Mix.shell().info("    ✓ Enriched")
          {:error, reason} -> Mix.shell().info("    ✗ Failed: #{inspect(reason)}")
        end
      else
        Mix.shell().info("  Skipping: #{page.slug} (body already #{body_len} chars)")
      end
    end

    Mix.shell().info("Done.")
  end

  defp enrich_pages(context, slug, _limit) do
    Mix.shell().info("Enriching single page '#{slug}' in '#{context.slug}'...")

    case Brain.get_page_by_slug(slug, context.id) do
      nil ->
        Mix.shell().error("Page '#{slug}' not found")

      page ->
        case TagEnricher.enrich_page(page) do
          {:ok, _} -> Mix.shell().info("  ✓ Enriched")
          {:error, reason} -> Mix.shell().error("  ✗ Failed: #{inspect(reason)}")
        end
    end
  end

  defp tag_has_page?(tag, context_id) do
    case Brain.get_page_by_slug(tag, context_id) do
      nil ->
        pages = Brain.list_pages(context_id: context_id, limit: 500)
        Enum.any?(pages, fn p -> String.starts_with?(p.slug, tag) end)

      _ ->
        true
    end
  end
end
