defmodule Dran.Summaries do
  @moduledoc """
  High-level helpers for suggesting page metadata with the inference API.

  Provides chat-based helpers that call the configured chat-compatible model
  (default "Ornith-1.0-9B") through `Dran.Inference.chat/1`. The main entry
  point is `augment_page/1` which asks for summary, tags, and entities in a
  single request.

  All text sent to the model is truncated via `Dran.Embeddings.truncate_body/1`
  so the embedding and the augmentation use the same window.
  """

  alias Dran.Brain
  alias Dran.Brain.Page
  alias Dran.Embeddings
  alias Dran.Inference
  alias Dran.Repo

  import Ecto.Query, warn: false

  @doc """
  Suggest a one-line summary, kebab-case tags, and entity names for `page`
  in a single inference call.

  Returns `{:ok, %{summary: "...", tags: [...], entities: [...]}}`
  or `{:error, :not_configured}`.
  """
  @spec augment_page(Page.t()) :: {:ok, map()} | {:error, term()}
  def augment_page(%Page{} = page) do
    with :ok <- ensure_configured(),
         {:ok, content} <- chat(page, augment_prompt(page)) do
      decoded = decode_json_with_fallback(content)

      result = %{
        title: Map.get(decoded, "title", "") |> String.trim(),
        summary: Map.get(decoded, "summary", "") |> String.trim(),
        tags:
          Map.get(decoded, "tags", [])
          |> List.wrap()
          |> Enum.map(&to_string/1)
          |> Enum.map(&slugify/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.uniq(),
        entities:
          Map.get(decoded, "entities", [])
          |> List.wrap()
          |> Enum.map(&to_string/1)
          |> Enum.reject(&(&1 == "")),
        inline_links:
          Map.get(decoded, "inline_links", [])
          |> List.wrap()
          |> Enum.map(&parse_inline_link/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()
      }

      {:ok, result}
    end
  end

  @doc """
  Suggest a one-line summary for `page`.
  """
  @spec summarize_page(Page.t()) :: {:ok, String.t()} | {:error, term()}
  def summarize_page(%Page{} = page) do
    case augment_page(page) do
      {:ok, %{summary: summary}} -> {:ok, summary}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Suggest kebab-case tags for `page`.
  """
  @spec suggest_tags(Page.t()) :: {:ok, [String.t()]} | {:error, term()}
  def suggest_tags(%Page{} = page) do
    case augment_page(page) do
      {:ok, %{tags: tags}} -> {:ok, tags}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Prompts ──

  defp augment_prompt(%Page{context_id: context_id} = page) do
    pages =
      if context_id do
        candidate_pages(page)
      else
        []
      end

    available_pages =
      pages
      |> Enum.take(50)
      |> Enum.map_join("\n", fn %{slug: slug, title: title, summary: summary} ->
        summary = summary || ""
        "- slug: #{slug}, title: #{title}#{if summary != "", do: ", summary: " <> summary, else: ""}"
      end)

    """
    You are a knowledge-base assistant. Analyze the given page and return a single JSON object with these keys:

    - "title": a concise title for the page (max 512 chars)
    - "summary": one concise sentence describing the page (max 120 chars)
    - "tags": 1-5 kebab-case tags
    - "entities": names of people, companies, products, tools or places mentioned (optional)
    - "inline_links": array of {"text": "exact text from body", "slug": "slug from available pages"} — link body text to related pages. Only use slugs from the available pages list. Pick the most relevant 1-5 links. The "text" must be an exact substring from the page body.

    Available pages in this context:

    #{available_pages}

    Respond with valid JSON and nothing else:

    {"title": "...", "summary": "...", "tags": [...], "entities": [...], "inline_links": [{"text": "...", "slug": "..."}]}
    """
  end

  @doc """
  Select up to 50 candidate pages for inline links, preferring semantic
  closeness to `page` when an embedding is available.

  Falls back to `Brain.list_pages/1` (recency-sorted) when `page` has no
  embedding.
  """
  @spec candidate_pages(Page.t()) :: [map()]
  def candidate_pages(%Page{} = page) do
    if page.embedding do
      vec = Pgvector.new(page.embedding)

      Repo.all(
        from p in Page,
          where: p.context_id == ^page.context_id and p.id != ^page.id,
          where: not is_nil(p.embedding),
          order_by: fragment("? <=> ?", p.embedding, ^vec),
          limit: 50,
          select: %{slug: p.slug, title: p.title, summary: coalesce(p.summary, "")}
      )
    else
      Brain.list_pages(context_id: page.context_id, limit: 50)
      |> Enum.reject(&(&1.id == page.id))
      |> Enum.map(&%{slug: &1.slug, title: &1.title, summary: &1.summary || ""})
    end
  end

  # ── Inference ──

  defp chat(%Page{} = page, system_prompt) do
    payload = %{
      "model" => Inference.chat_model(),
      "messages" => [
        %{"role" => "system", "content" => system_prompt},
        %{"role" => "user", "content" => page_text(page)}
      ],
      "temperature" => 0.3,
      "response_format" => %{"type" => "json_object"}
    }

    case Inference.chat(payload) do
      {:ok, message} -> {:ok, Map.get(message, "content", "")}
      {:error, reason} -> {:error, reason}
    end
  end

  defp page_text(%Page{} = page) do
    body = Embeddings.truncate_body(page.body)

    parts = [
      "Title: #{page.title || ""}",
      maybe_summary(page.summary),
      "Body:",
      body
    ]

    parts
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp maybe_summary(nil), do: nil
  defp maybe_summary(summary) when summary == "", do: nil
  defp maybe_summary(summary), do: "Summary: #{summary}"

  # ── JSON decoding ──

  defp decode_json_with_fallback(text) when is_binary(text) do
    text
    |> extract_json_object()
    |> case do
      nil ->
        %{}

      json ->
        case Jason.decode(json) do
          {:ok, decoded} when is_map(decoded) -> decoded
          _ -> %{}
        end
    end
  end

  defp decode_json_with_fallback(_), do: %{}

  defp extract_json_object(text) do
    text = String.trim(text)

    text =
      case Regex.run(~r/```(?:json)?\s*(\{.*?\})\s*```/s, text) do
        [_, inner] -> inner
        _ -> text
      end

    case Regex.run(~r/\{.*\}/s, text) do
      [json] -> json
      _ -> nil
    end
  end

  # ── Utilities ──

  defp ensure_configured do
    if Inference.enabled?() do
      :ok
    else
      {:error, :not_configured}
    end
  end

  defp slugify(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.replace(~r/^-+|-+$/, "")
  end

  defp parse_inline_link(%{"text" => text, "slug" => slug})
       when is_binary(text) and is_binary(slug) do
    text = String.trim(text)
    slug = String.trim(slug)

    if text != "" and slug != "" do
      %{text: text, slug: slug}
    end
  end

  defp parse_inline_link(_), do: nil
end
