defmodule Dran.Brain.PageAugmenter do
  @moduledoc """
  Asynchronously augments a page after creation or update.

  The augmentation pipeline:

  1. Generates and stores an embedding for the page (no-op if already current).
  2. Calls the inference API once to extract summary, keywords, entities and
     suggested wikilinks.
  3. Finds semantically similar pages in the same context.
  4. Creates `related` relations when both semantic similarity and the LLM agree
     (high confidence path).

  All work runs under `Dran.Relations.TaskSupervisor` so the HTTP/MCP request
  that created the page returns immediately.
  """

  require Logger

  alias Dran.Repo
  alias Dran.Brain
  alias Dran.Brain.Page
  alias Dran.Embeddings
  alias Dran.Inference
  alias Dran.Summaries

  @semantic_threshold 0.22
  @suggestion_limit 5

  @doc """
  Schedule async augmentation for a page.
  """
  @spec schedule(Page.t()) :: :ok | :ignored
  def schedule(%Page{} = page) do
    cond do
      not Inference.enabled?() ->
        :ignored

      schedule_async?() ->
        Task.Supervisor.start_child(
          Dran.Relations.TaskSupervisor,
          fn -> run(page) end,
          restart: :transient
        )

        :ok

      true ->
        run(page)
        :ok
    end
  end

  @doc """
  Run augmentation synchronously for the given page.
  """
  @spec run(Page.t()) :: :ok | {:error, term()}
  def run(%Page{} = page) do
    page = Repo.get(Page, page.id) || page

    with {:ok, enrich} <- maybe_enrich_metadata(page),
         :ok <- ensure_embedding(enrich),
         {:ok, neighbors} <- find_semantic_neighbors(enrich),
         {:ok, suggestions} <- Summaries.suggest_wikilinks(enrich) do
      target_ids =
        neighbors
        |> Enum.filter(fn %{distance: distance} -> distance <= @semantic_threshold end)
        |> Enum.map(& &1.id)

      create_relations(enrich, target_ids, suggestions)
      :ok
    else
      {:error, :not_configured} ->
        Logger.info("PageAugmenter skipped for #{page.slug}: inference not configured")
        :ok

      {:error, reason} ->
        Logger.warning("PageAugmenter failed for #{page.slug}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ── Metadata enrichment ──

  defp maybe_enrich_metadata(%Page{} = page) do
    case Summaries.augment_page(page) do
      {:ok, %{summary: summary, tags: tags}} ->
        attrs = %{
          summary: pick_summary(page.summary, summary),
          tags: merge_tags(page.tags || [], tags)
        }

        page
        |> Ecto.Changeset.change(attrs)
        |> Repo.update()

      {:error, :not_configured} ->
        {:ok, page}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp pick_summary(existing, _suggested) when is_binary(existing) and existing != "",
    do: existing

  defp pick_summary(_, suggested), do: suggested

  defp merge_tags(existing, suggested) do
    (existing ++ suggested)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  # ── Embedding ──

  defp ensure_embedding(%Page{} = page) do
    if Embeddings.needs_embedding?(page) do
      case Embeddings.generate(page) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  # ── Semantic neighbors ──

  defp find_semantic_neighbors(%Page{context_id: nil}), do: {:ok, []}

  defp find_semantic_neighbors(%Page{} = page) do
    text = Embeddings.text_for_page(page)

    case Brain.semantic_search(text, context_id: page.context_id, limit: @suggestion_limit + 1) do
      {:ok, results} ->
        neighbors =
          results
          |> Enum.reject(&(&1.id == page.id))
          |> Enum.take(@suggestion_limit)

        {:ok, neighbors}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Relations ──

  defp create_relations(page, neighbor_ids, suggested_slugs) do
    suggested_set = MapSet.new(suggested_slugs)

    neighbor_ids
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.each(fn target_id ->
      target = Repo.get(Page, target_id)

      if target && target.id != page.id do
        confidence =
          if target.slug in suggested_set do
            :high
          else
            :medium
          end

        maybe_create_relation(page, target, confidence)
      end
    end)

    suggested_slugs
    |> Enum.reject(&(&1 == page.slug))
    |> Enum.uniq()
    |> Enum.each(fn slug ->
      case Brain.get_page_by_slug(slug, page.context_id) do
        nil -> :ok
        target -> maybe_create_relation(page, target, :high)
      end
    end)
  end

  defp maybe_create_relation(page, target, confidence) do
    existing =
      Brain.list_relations_for_page(page.id)
      |> Map.get(:outbound, [])
      |> Enum.any?(&(&1.target_id == target.id))

    if existing do
      :ok
    else
      case Brain.create_relation(%{
             source_id: page.id,
             target_id: target.id,
             relation_type: "related",
             meta: %{"auto" => true, "confidence" => Atom.to_string(confidence)}
           }) do
        {:ok, _} -> :ok
        {:error, _} -> :ok
      end
    end
  end

  # ── Config ──

  defp schedule_async? do
    Dran.Inference.Config.config()
    |> Kernel.||(schedule_async: true)
    |> Keyword.get(:schedule_async, true)
  end
end
