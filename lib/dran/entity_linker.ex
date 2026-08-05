defmodule Dran.EntityLinker do
  @moduledoc """
  Entity linking: turns the entity names that `Dran.Summaries.augment_page/1`
  already extracts from the LLM into first-class graph nodes.

  For each entity mention in a page:

  1. **Get-or-create** an `entity` page in the same context (deduped by slug).
  2. **Create a `mentions` relation** from the source page to the entity page.

  Entity pages act as natural hubs in the graph — community detection and
  PageRank both benefit because `mentions` edges carry real weight
  (`Dran.Graph.edge_weight("mentions") == 0.6`).

  The linker does NOT call the LLM itself — it consumes the entities the
  augmenter already extracted, so it adds zero inference cost.

  ## Safety rails

  * Skips entities that would collide with an existing non-entity page of
    the same slug (we never hijack a note's slug).
  * Skips self-links (an entity page mentioning itself).
  * Relations are created with `on_conflict: :nothing` via
    `Brain.create_relation/1`, so re-running is idempotent.
  """

  require Logger

  alias Dran.Brain
  alias Dran.Brain.Page
  alias Dran.Slug

  @max_entities_per_page 10

  @doc """
  Link a page to entity pages for each name in `entities`.

  Returns `{:ok, created_count}` where `created_count` is the number of new
  `mentions` relations created (entity pages that already existed are not
  counted as failures — they are reused).
  """
  @spec link(Page.t(), [String.t()]) :: {:ok, non_neg_integer()}
  def link(%Page{context_id: nil}, _entities), do: {:ok, 0}

  def link(%Page{} = page, entities) when is_list(entities) do
    created =
      entities
      |> normalize_entities()
      |> Enum.reject(&(&1 == page.slug))
      |> Enum.take(@max_entities_per_page)
      |> Enum.reduce(0, fn entity_slug, acc ->
        case link_one(page, entity_slug) do
          {:ok, :linked} -> acc + 1
          _ -> acc
        end
      end)

    {:ok, created}
  end

  @doc """
  Normalize raw entity names into kebab-case slugs, dropping empties and
  duplicates.
  """
  @spec normalize_entities([String.t()]) :: [String.t()]
  def normalize_entities(entities) do
    entities
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&Slug.slugify/1)
    |> Enum.reject(&(&1 == "" or &1 == "untitled"))
    |> Enum.uniq()
  end

  # ── Internals ──

  defp link_one(page, entity_slug) do
    with {:ok, entity_page} <- get_or_create_entity(page, entity_slug),
         :ok <- create_mentions_edge(page, entity_page) do
      {:ok, :linked}
    else
      {:skip, reason} ->
        Logger.debug("EntityLinker skip #{entity_slug}: #{reason}")
        {:error, reason}

      {:error, reason} ->
        Logger.warning("EntityLinker failed #{entity_slug}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp get_or_create_entity(page, entity_slug) do
    case Brain.get_page_by_slug(entity_slug, page.context_id) do
      nil ->
        create_entity_page(page, entity_slug)

      %Page{page_type: "entity"} = existing ->
        {:ok, existing}

      %Page{page_type: other} ->
        {:skip, "slug taken by #{other} page"}
    end
  end

  defp create_entity_page(page, entity_slug) do
    attrs = %{
      context_id: page.context_id,
      title: titleize(entity_slug),
      slug: entity_slug,
      page_type: "entity",
      body: "",
      owner: page.owner || "system",
      created_by: "entity_linker",
      meta: %{"auto" => true, "created_from" => "entity_linker"}
    }

    case Brain.create_page(attrs) do
      {:ok, entity_page} ->
        {:ok, entity_page}

      {:error, %Ecto.Changeset{} = changeset} ->
        # Race: another augmenter created it concurrently — fetch and reuse.
        case Brain.get_page_by_slug(entity_slug, page.context_id) do
          %Page{page_type: "entity"} = existing ->
            {:ok, existing}

          _ ->
            {:error, changeset}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_mentions_edge(page, entity_page) do
    case Brain.create_relation(%{
           source_id: page.id,
           target_id: entity_page.id,
           relation_type: "mentions",
           meta: %{"auto" => true, "created_from" => "entity_linker"}
         }) do
      {:ok, _} -> :ok
      # on_conflict: :nothing returns the struct unchanged on dupes — treat as ok
      {:error, _} -> :ok
    end
  end

  defp titleize(slug) do
    slug
    |> String.split("-")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end
end
