defmodule Dran.PageAugmenter do
  @moduledoc """
  Asynchronously augments a page after creation or update.

  The augmentation pipeline:

  1. Materializes `meta.props` into typed relations (inference-independent).
  2. Calls the inference API once to extract title, summary, tags, entities,
     and inline links.
  3. Generates and stores an embedding for the page (no-op if already current).
  4. Finds semantically similar pages in the same context.
  5. Creates `semantic` relations for the closest neighbours.

  All work runs under `Dran.Relations.TaskSupervisor` so the HTTP/MCP request
  that created the page returns immediately.
  """

  require Logger

  alias Dran.Repo
  alias Dran.Brain
  alias Dran.Page
  alias Dran.Embeddings
  alias Dran.Inference
  alias Dran.Summaries

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
  rescue
    # TaskSupervisor may not be running during release tasks (bin/dran eval,
    # seeds) where only the repo is started. Augmentation is a background
    # enhancement, not a data-integrity concern — safe to skip.
    _ -> :ignored
  end

  @doc """
  Run augmentation synchronously for the given page.
  """
  @spec run(Page.t()) :: :ok | {:error, term()}
  def run(%Page{} = page) do
    # All page types get augmented — the guard was removed in Wave 6.
    do_run(page)
  end

  defp do_run(%Page{} = page) do
    page = Repo.get(Page, page.id) || page

    # Props materialization is inference-independent — run it first so props
    # always become edges even when the LLM is not configured.
    materialize_props(page)

    with {:ok, enrich} <- maybe_enrich_metadata(page),
         :ok <- ensure_embedding(enrich),
         {:ok, neighbors} <- find_semantic_neighbors(enrich) do
      threshold = semantic_threshold(enrich)

      target_ids =
        neighbors
        |> Enum.filter(fn %{distance: distance} -> distance <= threshold end)
        |> Enum.map(& &1.id)

      create_relations(enrich, target_ids)
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
      {:ok, %{title: title, summary: summary, tags: tags, inline_links: inline_links} = enrich} ->
        existing_meta = page.meta || %{}

        updated_meta =
          Map.put(existing_meta, "inline_links", serialize_inline_links(inline_links))

        attrs = %{
          title: pick_title(page.title, title),
          summary: pick_summary(page.summary, summary),
          tags: merge_tags(page.tags || [], tags),
          meta: updated_meta
        }

        with {:ok, updated_page} <-
               page
               |> Ecto.Changeset.change(attrs)
               |> Repo.update() do
          link_entities(updated_page, Map.get(enrich, :entities, []))
          {:ok, updated_page}
        end

      {:error, :not_configured} ->
        {:ok, page}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Entity linking: consume the entities the LLM already extracted and turn
  # them into entity pages + `mentions` relations. Zero extra inference cost.
  # Failures here must not break the augmentation pipeline — linking is a
  # best-effort enhancement.
  defp link_entities(page, entities) do
    if Dran.Settings.get("entity_linker_enabled") != false do
      case Dran.EntityLinker.link(page, entities) do
        {:ok, 0} ->
          :ok

        {:ok, count} ->
          Logger.debug("EntityLinker created #{count} mentions for #{page.slug}")
          :ok
      end
    else
      Logger.debug("EntityLinker skipped for #{page.slug}: disabled by setting")
      :ok
    end
  rescue
    e ->
      Logger.warning("EntityLinker crashed for #{page.slug}: #{Exception.message(e)}")
      :ok
  end

  # Props materialization: turn meta.props custom properties into typed
  # relations so PageRank/communities/GraphRAG can see them. Same
  # best-effort pattern as link_entities — a crash never breaks the pipeline.
  defp materialize_props(page) do
    case Dran.PropsMaterializer.materialize(page) do
      {:ok, 0} ->
        :ok

      {:ok, count} ->
        Logger.debug("PropsMaterializer created #{count} relations for #{page.slug}")
        :ok
    end
  rescue
    e ->
      Logger.warning("PropsMaterializer crashed for #{page.slug}: #{Exception.message(e)}")
      :ok
  end

  defp pick_title(existing, _suggested) when is_binary(existing) and existing != "",
    do: existing

  defp pick_title(_existing, suggested) when is_binary(suggested) and suggested != "",
    do: suggested

  defp pick_title(existing, _), do: existing

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

  defp find_semantic_neighbors(%Page{workspace_id: nil}), do: {:ok, []}

  defp find_semantic_neighbors(%Page{} = page) do
    text = Embeddings.text_for_page(page)

    case Brain.semantic_search(text,
           workspace_id: page.workspace_id,
           limit: @suggestion_limit + 1
         ) do
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

  @doc """
  Dynamic cosine-distance threshold for accepting a semantic neighbour.

  Short pages carry less signal, so we demand a tighter match; long pages
  have richer embeddings and can be linked more liberally.

    * `body` <  500 chars  → 0.15
    * `body` > 4000 chars  → 0.28
    * otherwise           → 0.22
  """
  @spec semantic_threshold(Page.t()) :: float()
  def semantic_threshold(%Page{body: body}) when is_binary(body) do
    cond do
      String.length(body) < 500 -> Dran.Settings.get("semantic_threshold_short")
      String.length(body) > 4000 -> Dran.Settings.get("semantic_threshold_long")
      true -> Dran.Settings.get("semantic_threshold_mid")
    end
  end

  def semantic_threshold(%Page{body: _}), do: Dran.Settings.get("semantic_threshold_mid")

  defp create_relations(page, neighbor_ids) do
    target_ids =
      neighbor_ids
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.reject(&(&1 == page.id))

    if target_ids == [] do
      {:ok, :done}
    else
      # Load existing outbound semantic targets once (no N+1).
      existing_targets =
        Brain.list_relations_for_page(page.id)
        |> Map.get(:outbound, [])
        |> Enum.filter(&(&1.relation_type == "semantic"))
        |> MapSet.new(& &1.target_id)

      Enum.each(target_ids, fn target_id ->
        create_semantic_edge(page, target_id, existing_targets)
      end)

      {:ok, :done}
    end
  end

  # Creates A→B and the inverse B→A when missing.
  # `Brain.create_relation/1` uses `on_conflict: :nothing`, so attempting the
  # insert is safe even if a row already exists. We still consult the
  # `existing_targets` MapSet to avoid spurious inserts on the outbound side
  # and to know whether we need to create the inverse edge.
  defp create_semantic_edge(page, target_id, existing_targets) do
    meta = %{"auto" => true, "confidence" => "medium"}

    unless MapSet.member?(existing_targets, target_id) do
      Brain.create_relation(%{
        source_id: page.id,
        target_id: target_id,
        relation_type: "semantic",
        meta: meta
      })
    end

    # Inverse edge B→A — always attempt; on_conflict handles dedupe.
    Brain.create_relation(%{
      source_id: target_id,
      target_id: page.id,
      relation_type: "semantic",
      meta: meta
    })

    :ok
  end

  defp serialize_inline_links(links) when is_list(links) do
    Enum.map(links, fn %{text: text, slug: slug} ->
      %{"text" => text, "slug" => slug}
    end)
  end

  defp serialize_inline_links(_), do: []

  # ── Config ──

  defp schedule_async? do
    Dran.Inference.Config.config()
    |> Kernel.||(schedule_async: true)
    |> Keyword.get(:schedule_async, true)
  end
end
