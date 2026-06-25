defmodule Dran.Summaries do
  @moduledoc """
  High-level helpers for suggesting page metadata with the inference API.

  Provides chat-based helpers that call the configured chat-compatible model
  (default "Qwen3.6-35B-A3B") through `Dran.Inference.chat/1`. The main entry
  point is `augment_page/1` which asks for summary, tags, entities and
  suggested wikilinks in a single request.

  All text sent to the model is truncated via `Dran.Embeddings.truncate_body/1`
  so the embedding and the augmentation use the same window.
  """

  require Logger

  alias Dran.Brain
  alias Dran.Brain.Page
  alias Dran.Embeddings
  alias Dran.Inference

  @doc """
  Suggest a one-line summary, kebab-case tags, entity names and existing page
  slugs for `page` in a single inference call.

  Returns `{:ok, %{summary: "...", tags: [...], entities: [...], links: [...]}}`
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
        links:
          Map.get(decoded, "links", [])
          |> List.wrap()
          |> Enum.map(&to_string/1)
          |> Enum.reject(&(&1 == ""))
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

  @doc """
  Suggest existing page slugs in the same context that are related to `page`.

  Returns an empty list when inference is not configured (with a warning).
  """
  @spec suggest_wikilinks(Page.t()) :: {:ok, [String.t()]} | {:error, term()}
  def suggest_wikilinks(%Page{context_id: nil}), do: {:ok, []}

  def suggest_wikilinks(%Page{} = page) do
    existing_slugs =
      Brain.list_pages(context_id: page.context_id)
      |> Enum.map(& &1.slug)
      |> MapSet.new()

    if not Inference.enabled?() do
      Logger.warning("Inference not configured; returning empty wikilink suggestions")
      {:ok, []}
    else
      case augment_page(page) do
        {:ok, %{links: links}} ->
          {:ok, Enum.filter(links, &MapSet.member?(existing_slugs, &1))}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # ── Prompts ──

  defp augment_prompt(%Page{context_id: context_id}) do
    pages =
      if context_id do
        Brain.list_pages(context_id: context_id)
        |> Enum.map(&%{slug: &1.slug, title: &1.title, summary: &1.summary || ""})
      else
        []
      end

    available_pages =
      pages
      |> Enum.take(50)
      |> Enum.map_join("\n", fn %{slug: slug, title: title, summary: summary} ->
        "- slug: #{slug}, title: #{title}#{if summary != "", do: ", summary: " <> summary, else: ""}"
      end)

    """
    You are a knowledge-base assistant. Analyze the given page and return a single JSON object with these keys:

    - "title": a concise title for the page (max 80 chars)
    - "summary": one concise sentence describing the page (max 120 chars)
    - "tags": 1-5 kebab-case tags
    - "entities": names of people, companies, products, tools or places mentioned (optional)
    - "links": slugs from the available pages list that are genuinely related to the current page

    Available pages in this context:

    #{available_pages}

    Respond with valid JSON and nothing else:

    {"title": "...", "summary": "...", "tags": [...], "entities": [...], "links": [...]}
    """
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
end
