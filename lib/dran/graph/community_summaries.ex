defmodule Dran.Graph.CommunitySummaries do
  @moduledoc """
  Generate and query persisted summaries for graph communities.

  After community detection has stamped each page's `meta["community_id"]`,
  this module produces a 2-3 sentence natural-language summary per community
  (via `Dran.Inference.chat/1`) and stores it alongside the highest-ranked
  pages in a `community_summaries` row. The GraphRAG layer reads these back
  to answer questions about a community without re-querying the LLM.
  """

  import Ecto.Query

  alias Dran.Brain
  alias Dran.Brain.Page
  alias Dran.Graph.CommunitySummary
  alias Dran.Inference
  alias Dran.Repo

  # How many highest-ranked pages to include in the summary prompt and store.
  @top_n 10
  @max_concurrency 3

  @doc """
  Generate and persist summaries for all communities in a context.

  Loads every page in `workspace_id` with `meta->>'community_id'` set, groups
  them by community, and writes one `CommunitySummary` row per community
  (upsert on the `[:workspace_id, :community_id]` unique constraint). Inference
  calls run concurrently via `Task.async_stream`.

  When inference is not configured (`Dran.Inference.enabled?/0` is false) the
  LLM call is skipped and a deterministic fallback summary is used instead, so
  the pipeline never blocks on a missing server.
  """
  @spec generate_all(binary()) :: :ok | {:error, term()}
  def generate_all(workspace_id) when is_binary(workspace_id) do
    workspace_id
    |> load_community_pages()
    |> Enum.group_by(fn p -> parse_int(p.meta["community_id"]) end)
    |> Enum.reject(fn {cid, _pages} -> is_nil(cid) end)
    |> Task.async_stream(
      fn {community_id, pages} -> build_summary(workspace_id, community_id, pages) end,
      max_concurrency: @max_concurrency,
      timeout: :infinity,
      ordered: false,
      on_timeout: :kill_task
    )
    |> Enum.reduce_while(:ok, fn
      {:ok, :ok}, :ok -> {:cont, :ok}
      {:ok, {:error, reason}}, :ok -> {:halt, {:error, reason}}
      {:exit, reason}, :ok -> {:halt, {:error, reason}}
      _, acc -> {:cont, acc}
    end)
  end

  @doc "Get the summary for a specific community."
  @spec get_summary(binary(), integer()) ::
          {:ok, CommunitySummary.t()} | {:error, :not_found}
  def get_summary(workspace_id, community_id)
      when is_binary(workspace_id) and is_integer(community_id) do
    case Repo.get_by(CommunitySummary, workspace_id: workspace_id, community_id: community_id) do
      nil -> {:error, :not_found}
      summary -> {:ok, summary}
    end
  end

  @doc "Get the summary for the community a page belongs to."
  @spec get_summary_for_page(binary()) :: {:ok, CommunitySummary.t()} | {:error, :not_found}
  def get_summary_for_page(page_id) when is_binary(page_id) do
    page = Repo.get_by(Page, id: page_id)

    with %Page{} <- page,
         cid when is_integer(cid) <- parse_int(page.meta["community_id"]),
         {:ok, summary} <- get_summary(page.workspace_id, cid) do
      {:ok, summary}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "List all community summaries for a context, ordered by page_count desc."
  @spec list_summaries(binary()) :: [CommunitySummary.t()]
  def list_summaries(workspace_id) when is_binary(workspace_id) do
    Repo.all(
      from cs in CommunitySummary,
        where: cs.workspace_id == ^workspace_id,
        order_by: [desc: cs.page_count]
    )
  end

  @doc "Delete all summaries for a context (used before regenerating)."
  @spec delete_all(binary()) :: :ok
  def delete_all(workspace_id) when is_binary(workspace_id) do
    from(cs in CommunitySummary, where: cs.workspace_id == ^workspace_id)
    |> Repo.delete_all()

    :ok
  end

  @doc """
  Regenerate summaries for the default context (Quantum entrypoint).

  Same pattern as `Dran.Graph.refresh_all_scheduled/0`: resolves the default
  context slug via `Dran.Auth.default_workspace_slug/0` and looks it up with
  `Brain.get_workspace_by_slug/1`.
  """
  @spec generate_all_scheduled() :: :ok | {:error, :workspace_not_found}
  def generate_all_scheduled do
    slug = Dran.Auth.default_workspace_slug()

    case Brain.get_workspace_by_slug(slug) do
      nil ->
        {:error, :workspace_not_found}

      ctx ->
        generate_all(ctx.id)
    end
  end

  # ── Helpers ──

  defp load_community_pages(workspace_id) do
    Repo.all(
      from p in Page,
        where: p.workspace_id == ^workspace_id,
        where: fragment("meta->>'community_id' IS NOT NULL"),
        select: %{slug: p.slug, title: p.title, summary: p.summary, meta: p.meta}
    )
  end

  defp build_summary(workspace_id, community_id, community_pages) do
    page_count = length(community_pages)

    top =
      community_pages
      |> Enum.sort_by(&pagerank_of/1, :desc)
      |> Enum.take(@top_n)

    top_pages =
      Enum.map(top, fn p ->
        %{slug: p.slug, title: p.title || "", pagerank: pagerank_of(p)}
      end)

    summary =
      if Inference.enabled?() do
        summarize_with_llm(top)
      else
        fallback_summary(page_count, top_pages)
      end

    upsert_summary(workspace_id, community_id, summary, page_count, top_pages)
  end

  defp summarize_with_llm(top) do
    system_prompt = """
    You are a knowledge graph analyst. Given a community of related pages from a personal knowledge base, write a 2-3 sentence summary that captures the main theme and key topics of this community. Be concise and specific.

    Pages in this community (ordered by importance):
    #{prompt_pages(top)}

    Write only the summary, no preamble.
    """

    payload = %{
      "model" => Inference.chat_model(),
      "messages" => [
        %{"role" => "system", "content" => system_prompt},
        %{"role" => "user", "content" => "Write the community summary."}
      ],
      "temperature" => 0.3
    }

    case Inference.chat(payload) do
      {:ok, %{"content" => content}} when is_binary(content) and content != "" ->
        String.trim(content)

      {:ok, _} ->
        fallback_summary(length(top), top_pages_from_pages(top))

      {:error, _reason} ->
        fallback_summary(length(top), top_pages_from_pages(top))
    end
  end

  defp fallback_summary(page_count, top_pages) do
    titles = Enum.map_join(top_pages, ", ", & &1.title)
    "Community of #{page_count} pages including: #{titles}"
  end

  defp prompt_pages(top) do
    top
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {p, i} ->
      summary = p.summary || ""
      "#{i}. #{p.title || ""} — #{summary}"
    end)
  end

  defp top_pages_from_pages(top) do
    Enum.map(top, fn p -> %{slug: p.slug, title: p.title || "", pagerank: pagerank_of(p)} end)
  end

  defp upsert_summary(workspace_id, community_id, summary, page_count, top_pages) do
    attrs = %{
      workspace_id: workspace_id,
      community_id: community_id,
      summary: summary,
      page_count: page_count,
      top_pages: top_pages,
      generated_at: DateTime.utc_now()
    }

    case Repo.insert(
           CommunitySummary.changeset(%CommunitySummary{}, attrs),
           on_conflict: {:replace, [:summary, :page_count, :top_pages, :generated_at]},
           conflict_target: [:workspace_id, :community_id]
         ) do
      {:ok, _summary} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp pagerank_of(page), do: parse_float(page.meta["pagerank"])

  defp parse_int(nil), do: nil
  defp parse_int(v) when is_integer(v), do: v
  defp parse_int(v) when is_float(v), do: round(v)

  defp parse_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {i, _rest} -> i
      :error -> nil
    end
  end

  defp parse_int(_), do: nil

  defp parse_float(nil), do: 0.0
  defp parse_float(v) when is_float(v), do: v
  defp parse_float(v) when is_integer(v), do: v * 1.0

  defp parse_float(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _rest} -> f
      :error -> 0.0
    end
  end

  defp parse_float(_), do: 0.0
end
