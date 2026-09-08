defmodule Dran.PageSummaries do
  @moduledoc """
  LLM-generated summaries for pages that lack one.

  `summary` is a machine-owned field: it is written by MCP/REST (agents) or
  by this backfill — never by a human in the UI. This module implements the
  nightly backfill that fills the gap: for every non-archived page in every
  workspace whose `summary` is empty, ask the inference API for a one-line
  summary and persist it.

  Only summary-less pages are touched (`pick_summary/2` semantics from
  `Dran.PageAugmenter`: an existing summary is never overwritten), and pages
  with empty bodies are skipped (nothing to summarize).

  Entrypoints:

    * `backfill_all/0` — every workspace (Quantum entrypoint).
    * `backfill/1` — one workspace (tests, targeted runs).
    * `run_scheduled/0` — same as `backfill_all/0`, markdown report for
      `Dran.Jobs` (registered as the `page_summaries_nightly` job).

  Degrades to `{:error, :not_configured}` when inference is off — the job
  report records it and nothing else happens.
  """

  import Ecto.Query

  alias Dran.{Inference, Knowledge, Repo}
  alias Dran.Knowledge.Page
  alias Dran.Summaries

  require Logger

  # Inference calls run with bounded concurrency, matching the pattern of
  # Dran.Graph.ClusterSummaries (LLM calls are the expensive part).
  @max_concurrency 3
  @max_pages_per_run 500

  @doc """
  Backfill missing page summaries for ALL workspaces.

  Returns `{:error, :not_configured}` when inference is disabled. Otherwise
  returns `{:ok, %{filled: n, skipped: n, errors: n}}`.
  """
  @spec backfill_all() :: {:ok, map()} | {:error, :not_configured}
  def backfill_all do
    with :ok <- ensure_configured() do
      results =
        Knowledge.list_workspaces()
        |> Enum.map(&backfill(&1.id))
        |> Enum.reduce(%{filled: 0, skipped: 0, errors: 0}, &merge_results/2)

      {:ok, results}
    end
  end

  @doc """
  Backfill missing summaries for a single workspace.
  """
  @spec backfill(binary()) :: {:ok, map()} | {:error, :not_configured}
  def backfill(workspace_id) when is_binary(workspace_id) do
    with :ok <- ensure_configured() do
      workspace_id
      |> pending_pages()
      |> Task.async_stream(
        &summarize_and_persist/1,
        max_concurrency: @max_concurrency,
        timeout: :infinity,
        ordered: false,
        on_timeout: :kill_task
      )
      |> Enum.reduce(%{filled: 0, skipped: 0, errors: 0}, fn
        {:ok, :filled}, acc -> Map.update!(acc, :filled, &(&1 + 1))
        {:ok, :skipped}, acc -> Map.update!(acc, :skipped, &(&1 + 1))
        _entry, acc -> Map.update!(acc, :errors, &(&1 + 1))
      end)
      |> then(&{:ok, &1})
    end
  end

  @doc """
  Quantum entrypoint — runs `backfill_all/0` and renders a markdown report
  (the `Dran.Jobs` log convention: return value becomes the report body).

  When inference is not configured the job is reported as skipped (a normal
  run with zero work), not as an error — a missing LLM server is expected
  in some deployments and should not page anyone.
  """
  @spec run_scheduled() :: String.t()
  def run_scheduled do
    case backfill_all() do
      {:ok, results} ->
        report_body(results)

      {:error, :not_configured} ->
        "Skipped — inference is not configured."
    end
  end

  @doc """
  Markdown body for the backfill report (Dran.Jobs log convention).
  """
  @spec report_body(map()) :: String.t()
  def report_body(results) do
    """
    # Page summaries backfill

    Filled #{results.filled} · Skipped #{results.skipped} · Errors #{results.errors}
    """
    |> String.trim()
  end

  # ── Internals ─────────────────────────────────────────────────────────────

  defp ensure_configured do
    if Inference.enabled?(), do: :ok, else: {:error, :not_configured}
  end

  defp pending_pages(workspace_id) do
    Repo.all(
      from p in Page,
        where:
          p.workspace_id == ^workspace_id and
            p.archived == false and
            (is_nil(p.summary) or p.summary == ""),
        where: not (is_nil(p.body) or p.body == ""),
        limit: ^@max_pages_per_run
    )
  end

  defp summarize_and_persist(%Page{} = page) do
    case Summaries.summarize_page(page) do
      {:ok, summary} when is_binary(summary) and summary != "" ->
        page
        |> Ecto.Changeset.change(summary: summary)
        |> Repo.update()
        |> case do
          {:ok, _} ->
            :filled

          {:error, changeset} ->
            Logger.warning(
              "PageSummaries: could not save summary for #{page.slug}: #{inspect(changeset.errors)}"
            )

            :error
        end

      {:ok, _other} ->
        :skipped

      {:error, reason} ->
        Logger.warning("PageSummaries: summarize failed for #{page.slug}: #{inspect(reason)}")
        :error
    end
  end

  defp merge_results({:ok, partial}, acc),
    do: %{
      filled: acc.filled + partial.filled,
      skipped: acc.skipped + partial.skipped,
      errors: acc.errors + partial.errors
    }

  defp merge_results({:error, :not_configured}, acc), do: acc

  defp merge_results(_other, acc), do: acc
end
