defmodule Dran.Summaries do
  @moduledoc """
  High-level helpers for suggesting page metadata with the inference API.

  Provides three chat-based helpers:

  - `summarize_page/1` — one-line summary from title + body.
  - `suggest_tags/1` — relevant kebab-case tags from title + body.
  - `suggest_wikilinks/1` — existing page slugs in the same context that are
    related to the current page.

  All helpers talk to the configured chat-compatible model (default
  "Qwen3.6-35B-A3B") through `Dran.Inference.chat/1`.  When inference is not
  configured, `summarize_page/1` and `suggest_tags/1` return
  `{:error, :not_configured}`; `suggest_wikilinks/1` degrades to `{:ok, []}`
  and logs a warning.
  """

  require Logger

  alias Dran.Brain
  alias Dran.Brain.Page
  alias Dran.Inference

  @max_body_chars 3_000

  @doc """
  Suggest a one-line summary for `page`.
  """
  @spec summarize_page(Page.t()) :: {:ok, String.t()} | {:error, term()}
  def summarize_page(%Page{} = page) do
    with :ok <- ensure_configured(),
         {:ok, content} <- chat(page, summary_prompt()) do
      summary =
        content
        |> decode_json_with_fallback()
        |> Map.get("summary", "")
        |> String.trim()

      {:ok, summary}
    end
  end

  @doc """
  Suggest kebab-case tags for `page`.
  """
  @spec suggest_tags(Page.t()) :: {:ok, [String.t()]} | {:error, term()}
  def suggest_tags(%Page{} = page) do
    with :ok <- ensure_configured(),
         {:ok, content} <- chat(page, tags_prompt()) do
      tags =
        content
        |> decode_json_with_fallback()
        |> Map.get("tags", [])
        |> List.wrap()
        |> Enum.map(&to_string/1)
        |> Enum.map(&slugify/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()

      {:ok, tags}
    end
  end

  @doc """
  Suggest existing page slugs in the same context that are related to `page`.

  Returns an empty list when inference is not configured (with a warning).
  """
  @spec suggest_wikilinks(Page.t()) :: {:ok, [String.t()]} | {:error, term()}
  def suggest_wikilinks(%Page{context_id: nil}), do: {:ok, []}

  def suggest_wikilinks(%Page{} = page) do
    links =
      Brain.list_pages(context_id: page.context_id)
      |> Enum.reject(&(&1.slug == page.slug))
      |> Enum.map(&%{slug: &1.slug, title: &1.title, summary: &1.summary || ""})

    if not Inference.enabled?() do
      Logger.warning("Inference not configured; returning empty wikilink suggestions")
      {:ok, []}
    else
      prompt = wikilinks_prompt(links)

      with {:ok, content} <- chat(page, prompt) do
        slugs =
          content
          |> decode_json_with_fallback()
          |> Map.get("links", [])
          |> List.wrap()
          |> Enum.map(&to_string/1)
          |> Enum.filter(&(&1 in Enum.map(links, fn p -> p.slug end)))

        {:ok, slugs}
      end
    end
  end

  # ── Prompts ──

  defp summary_prompt do
    """
    You summarize knowledge-base pages into a single concise sentence.
    Respond with valid JSON: {"summary": "..."}. Keep it under 120 characters.
    """
  end

  defp tags_prompt do
    """
    You suggest relevant kebab-case tags for a knowledge-base page.
    Respond with valid JSON: {"tags": ["tag-one", "tag-two"]}. Use 1-5 tags.
    """
  end

  defp wikilinks_prompt(links) when links == [] do
    """
    There are no other pages in this context. Respond with valid JSON: {"links": []}.
    """
  end

  defp wikilinks_prompt(links) do
    items =
      Enum.map_join(links, "\n", fn %{slug: slug, title: title, summary: summary} ->
        "- slug: #{slug}, title: #{title}#{if summary != "", do: ", summary: " <> summary, else: ""}"
      end)

    """
    You pick relevant existing page slugs to link to from the current page.
    Available pages in this context:

    #{items}

    Respond with valid JSON: {"links": ["slug-one", "slug-two"]}. Only include slugs from the list.
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
      "temperature" => 0.3
    }

    case Inference.chat(payload) do
      {:ok, message} -> {:ok, Map.get(message, "content", "")}
      {:error, reason} -> {:error, reason}
    end
  end

  defp page_text(%Page{} = page) do
    body = String.slice(page.body || "", 0, @max_body_chars)

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

    # Strip markdown code fences if present.
    text =
      case Regex.run(~r/```(?:json)?\s*(\{.*?\})\s*```/s, text) do
        [_, inner] -> inner
        _ -> text
      end

    # Grab the first top-level JSON object.
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
