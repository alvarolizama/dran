defmodule Dran.TagEnricher do
  @moduledoc """
  Auto-creates stub pages for tags that don't have a corresponding page.

  When a page is created or updated, the PageAugmenter extracts tags. This
  module checks each tag — if no page exists with that slug (or a slug
  starting with that tag), it:

  1. Searches the web via Firecrawl for information about the tag
  2. Scrapes the top results
  3. Asks the LLM to synthesize a concise stub page
  4. Creates the page with `page_type: "concept"` and the tag as slug

  Stubs are marked with `meta.auto_generated = true` for review.
  """

  require Logger

  alias Dran.Brain
  alias Dran.Firecrawl
  alias Dran.Inference

  @stub_page_type "concept"

  @doc """
  Enrich tags for a page: create stubs for missing tag pages.

  Returns `{:ok, created}` where `created` is a list of created page slugs.
  """
  @spec enrich_tags(Dran.Brain.Page.t()) :: {:ok, [String.t()]} | {:error, term()}
  def enrich_tags(%Brain.Page{} = page) do
    tags = page.tags || []

    if tags == [] or not Firecrawl.enabled?() do
      {:ok, []}
    else
      context = Brain.get_context!(page.context_id)

      created =
        tags
        |> Enum.filter(&(not tag_has_page?(&1, page.context_id)))
        |> Enum.map(&create_stub_page(&1, page.context_id, context.slug))
        |> Enum.reject(&is_nil/1)

      {:ok, created}
    end
  end

  @doc """
  Enrich a single page with web-sourced content.

  Searches the web for the page title + tags, scrapes results, and asks
  the LLM to generate improved body content. Updates the page if the new
  content is significantly better.
  """
  @spec enrich_page(Dran.Brain.Page.t()) :: {:ok, String.t()} | {:error, term()}
  def enrich_page(%Brain.Page{} = page) do
    with :ok <- ensure_firecrawl(),
         {:ok, results} <- search_for_page(page),
         {:ok, content} <- scrape_results(results),
         {:ok, improved_body} <- synthesize_body(page, content) do
      attrs = %{
        body: improved_body,
        meta: Map.put(page.meta || %{}, "enriched_at", DateTime.utc_now() |> DateTime.to_iso8601())
      }

      case Brain.update_page(page, attrs) do
        {:ok, updated} ->
          Logger.info("TagEnricher: enriched page #{page.slug}")
          {:ok, updated.body}

        {:error, reason} ->
          Logger.warning("TagEnricher: failed to update #{page.slug}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  # ── Tag stub creation ──

  defp tag_has_page?(tag, context_id) do
    # Check if a page exists with slug == tag OR slug starts with tag
    case Brain.get_page_by_slug(tag, context_id) do
      nil ->
        # Check prefix match
        pages = Brain.list_pages(context_id: context_id, limit: 500)
        Enum.any?(pages, fn p -> String.starts_with?(p.slug, tag) end)

      _page ->
        true
    end
  end

  defp create_stub_page(tag, context_id, _context_slug) do
    with {:ok, results} <- Firecrawl.search(tag, limit: 3),
         {:ok, content} <- scrape_results(results),
         {:ok, body} <- synthesize_stub(tag, content) do
      attrs = %{
        context_id: context_id,
        title: title_case(tag),
        slug: tag,
        body: body,
        page_type: @stub_page_type,
        tags: [tag],
        meta: %{"auto_generated" => true, "source_tag" => tag},
        created_by: "tag-enricher",
        owner: "tag-enricher"
      }

      case Brain.create_page(attrs) do
        {:ok, page} ->
          Logger.info("TagEnricher: created stub for tag '#{tag}' → #{page.slug}")
          page.slug

        {:error, %Ecto.Changeset{} = cs} ->
          Logger.warning("TagEnricher: failed to create stub for '#{tag}': #{inspect(cs.errors)}")
          nil
      end
    else
      {:error, reason} ->
        Logger.warning("TagEnricher: skipped stub for '#{tag}': #{inspect(reason)}")
        nil
    end
  end

  # ── Page enrichment ──

  defp search_for_page(%Brain.Page{} = page) do
    query = "#{page.title} #{Enum.join(page.tags || [], " ")}"
    Firecrawl.search(query, limit: 5)
  end

  defp scrape_results(results) when is_list(results) and results != [] do
    urls = Enum.map(results, & &1.url) |> Enum.take(3)

    scraped =
      urls
      |> Enum.map(&Firecrawl.scrape/1)
      |> Enum.filter(fn
        {:ok, _} -> true
        _ -> false
      end)
      |> Enum.map(fn {:ok, data} -> data end)

    if scraped != [] do
      content =
        scraped
        |> Enum.map_join("\n\n---\n\n", fn %{url: url, title: title, markdown: md} ->
          "## #{title}\nSource: #{url}\n\n#{String.slice(md || "", 0, 3000)}"
        end)

      {:ok, content}
    else
      {:error, :no_content}
    end
  end

  defp scrape_results(_), do: {:error, :no_results}

  defp synthesize_stub(tag, web_content) do
    prompt = """
    Create a concise encyclopedia-style stub page about "#{tag}".

    Use the following web search results as source material. Write in clear,
    informative prose. Maximum 3 paragraphs. Do NOT include the source URLs
    in the body — they are metadata only.

    Web results:
    #{web_content}
    """

    chat_with_llm(prompt)
  end

  defp synthesize_body(%Brain.Page{} = page, web_content) do
    prompt = """
    I have a knowledge-base page that needs enrichment. Here is the current content:

    Title: #{page.title}
    Tags: #{Enum.join(page.tags || [], ", ")}
    Current body:
    #{page.body || "(empty)"}

    Here is web-sourced information:
    #{web_content}

    Generate an improved body that combines the existing content with the web
    information. Keep the original tone and structure. Add new facts, context,
    and details from the web results. Do NOT include source URLs in the body.

    Respond with ONLY the markdown body, nothing else.
    """

    chat_with_llm(prompt)
  end

  # ── LLM ──

  defp chat_with_llm(prompt) do
    payload = %{
      "model" => Inference.chat_model(),
      "messages" => [
        %{"role" => "system", "content" => "You are a knowledge-base assistant. Generate concise, informative content in Markdown."},
        %{"role" => "user", "content" => prompt}
      ],
      "temperature" => 0.4
    }

    case Inference.chat(payload) do
      {:ok, message} ->
        content = Map.get(message, "content", "") |> String.trim()
        if content != "", do: {:ok, content}, else: {:error, :empty_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Helpers ──

  defp ensure_firecrawl do
    if Firecrawl.enabled?(), do: :ok, else: {:error, :firecrawl_not_configured}
  end

  defp title_case(tag) do
    tag
    |> String.split("-")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end
end
