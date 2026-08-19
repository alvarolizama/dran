defmodule Dran.Rerank do
  @moduledoc """
  Reranks search candidates using the configured reranker model.

  Takes a query and a list of candidate results (maps or `{page, excerpt}`
  tuples), builds a snippet from each, calls the reranker, and returns the
  candidates sorted by relevance score.

  When reranking is disabled, inference is not configured, or the reranker
  call fails, the original order is preserved.

  ## Configuration

  Reranking is **opt-in** via config. It is only active when both
  `Dran.Inference.Config.enabled?/0` and `Dran.Inference.Config.use_rerank?/0`
  return `true`. The `use_rerank` flag defaults to `false` in
  `Dran.Inference.Config` (though the env var
  `DRAN_INFERENCE_USE_RERANK` defaults to `"true"` when present).
  """

  alias Dran.Inference

  @type candidate :: map() | {Dran.Brain.Page.t(), String.t()}

  @doc """
  Rerank candidates.
  """
  @spec rerank(String.t(), list(candidate), keyword()) :: {:ok, list(candidate)}
  def rerank(query, candidates, opts \\ [])

  def rerank(_query, candidates, _opts) when candidates == [] do
    {:ok, candidates}
  end

  def rerank(query, candidates, opts) do
    if Inference.Config.enabled?() and Inference.Config.use_rerank?() do
      do_rerank(query, candidates, opts)
    else
      {:ok, candidates}
    end
  end

  defp do_rerank(query, candidates, _opts) do
    docs = Enum.map(candidates, &to_text/1)

    case Inference.rerank(query, docs) do
      {:ok, results} ->
        indexed_scores =
          results
          |> Enum.map(fn r -> {Map.get(r, "index"), Map.get(r, "relevance_score", 0.0)} end)
          |> Enum.into(%{})

        sorted =
          candidates
          |> Enum.with_index()
          |> Enum.sort_by(fn {_c, idx} -> Map.get(indexed_scores, idx, 0.0) end, :desc)
          |> Enum.map(fn {c, _idx} -> c end)

        {:ok, sorted}

      {:error, reason} ->
        require Logger
        Logger.warning("Rerank failed: #{inspect(reason)}. Falling back to original order.")
        {:ok, candidates}
    end
  end

  defp to_text({%Dran.Brain.Page{} = page, excerpt}) do
    [page.title, page.summary, excerpt, Enum.join(page.tags || [], " ")]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp to_text(candidate) when is_map(candidate) do
    parts = [
      Map.get(candidate, :title),
      Map.get(candidate, "title"),
      Map.get(candidate, :summary),
      Map.get(candidate, "summary"),
      Map.get(candidate, :excerpt),
      Map.get(candidate, "excerpt"),
      Map.get(candidate, :body),
      Map.get(candidate, "body")
    ]

    parts
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end
end
