defmodule Dran.PropsBackfill do
  @moduledoc """
  Backfills typed relations from `meta.props` for existing pages.

  Pages created before the PropsMaterializer existed (or whose props were
  added after their last augmentation) carry custom metadata that the graph
  cannot see. This module finds every page with a non-empty `meta.props`
  map and re-runs the augmenter on it, which materializes props into typed
  relations (`works_in`, `has_tier`, `based_in`, `written_in`, `built_with`).

  Runs synchronously inside the caller's Task (see `SettingsLive`).
  Returns `{:ok, %{pages: n, edges: n}}` or `{:error, reason}`.
  """

  require Logger

  import Ecto.Query

  alias Dran.Repo
  alias Dran.Page
  alias Dran.PageAugmenter

  @doc """
  Find all pages with non-empty `meta.props` and re-augment them.

  The augmenter is best-effort: a failure on one page logs a warning and
  continues with the rest. The returned stats count every page that was
  successfully re-augmented and the total number of new relations created.
  """
  @spec run() :: {:ok, %{pages: non_neg_integer(), edges: non_neg_integer()}} | {:error, term()}
  def run do
    pages = list_pages_with_props()

    stats =
      Enum.reduce(pages, %{pages: 0, edges: 0}, fn page, acc ->
        case count_edges_before(page) do
          before_count ->
            case safe_augment(page) do
              :ok ->
                after_count = count_edges_before(page)
                new_edges = max(after_count - before_count, 0)
                %{acc | pages: acc.pages + 1, edges: acc.edges + new_edges}

              {:error, reason} ->
                Logger.warning("PropsBackfill failed for #{page.slug}: #{inspect(reason)}")
                acc
            end
        end
      end)

    {:ok, stats}
  rescue
    e ->
      Logger.error("PropsBackfill crashed: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  # Pages whose meta->'props' exists and is not the empty object.
  defp list_pages_with_props do
    from(p in Page,
      where: fragment("meta->'props' IS NOT NULL"),
      where: fragment("meta->'props' != '{}'::jsonb")
    )
    |> Repo.all()
  end

  defp count_edges_before(page) do
    Dran.Brain.list_relations_for_page(page.id)
    |> Map.get(:outbound, [])
    |> length()
  end

  defp safe_augment(page) do
    # Clear embedding_hash so the augmenter treats the page as stale and
    # actually runs the full pipeline (metadata enrichment + props materialization).
    Ecto.Changeset.change(page, embedding_hash: nil) |> Repo.update!()

    case PageAugmenter.run(page) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end
end
