defmodule Dran.Graph.Maintenance do
  @moduledoc """
  Graph hygiene: keeps the automatically-generated `semantic` relation layer
  clean over time.

  Two operations:

  * **Pruning** — delete `semantic` relations whose cosine distance exceeds a
    threshold. Semantic relations accumulate (they are never deleted on
    re-embed), so stale, weak edges pile up. Pruning sweeps them out.

  * **Mutual k-NN filtering** — delete one-directional `semantic` relations.
    If A lists B among its nearest neighbours but B does NOT list A, the edge
    is far more likely to be a false positive than a mutual match. Keeping
    only reciprocated edges sharpens the graph considerably.

  Both operations only touch `relation_type = "semantic"` rows that carry a
  numeric distance in `weight` or `meta.distance` — hand-made or
  agent-proposed relations are never touched.

  Designed to run from a nightly cron job (`Dran.Scheduler`) and from the
  `mix dran.graph.prune` task for manual sweeps.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Dran.Repo
  alias Dran.Knowledge
  alias Dran.{Page, Relation}

  @doc """
  Prune weak `semantic` relations in a context.

  A relation is pruned when its stored cosine distance (from `weight` or
  `meta["distance"]`, whichever is present) is strictly greater than
  `threshold`.

  When `threshold` is `nil`, the long-body semantic threshold from settings
  (`semantic_threshold_long`) is used — the most permissive of the three
  augmenter thresholds, so anything above it is noise by construction.

  Returns the number of deleted relations (each direction counts separately).
  """
  @spec prune_semantic(binary(), float() | nil) :: non_neg_integer()
  def prune_semantic(workspace_id, threshold \\ nil) do
    threshold = threshold || Dran.Settings.get("semantic_threshold_long")

    semantic_relations(workspace_id)
    |> Enum.filter(fn rel -> distance_of(rel) != nil and distance_of(rel) > threshold end)
    |> Enum.map(& &1.id)
    |> delete_by_ids()
  end

  @doc """
  Keep only mutual `semantic` relations in a context.

  For every semantic edge A→B, the edge is kept only if the reciprocal
  edge B→A also exists (as `semantic`). One-directional edges are deleted.

  Returns the number of deleted relations.
  """
  @spec filter_mutual(binary()) :: non_neg_integer()
  def filter_mutual(workspace_id) do
    relations = semantic_relations(workspace_id)

    edge_set =
      relations
      |> Enum.map(fn rel -> {rel.source_id, rel.target_id} end)
      |> MapSet.new()

    relations
    |> Enum.filter(fn rel ->
      not MapSet.member?(edge_set, {rel.target_id, rel.source_id})
    end)
    |> Enum.map(& &1.id)
    |> delete_by_ids()
  end

  @doc """
  Full maintenance sweep for a context: prune weak edges first, then drop
  the remaining one-directional ones.

  Returns `%{pruned: n, non_mutual: n}`.
  """
  @spec sweep(binary()) :: %{pruned: non_neg_integer(), non_mutual: non_neg_integer()}
  def sweep(workspace_id) do
    pruned = prune_semantic(workspace_id)
    non_mutual = filter_mutual(workspace_id)

    Logger.info(
      "Graph.Maintenance sweep for context #{workspace_id}: " <>
        "pruned=#{pruned} non_mutual=#{non_mutual}"
    )

    %{pruned: pruned, non_mutual: non_mutual}
  end

  @doc """
  Scheduled entrypoint: sweep the default context (same resolution pattern
  as `Dran.Graph.refresh_all_scheduled/0`).
  """
  @spec sweep_scheduled() :: :ok | {:error, :workspace_not_found}
  def sweep_scheduled do
    slug = Dran.Auth.default_workspace_slug()

    case Knowledge.get_workspace_by_slug(slug) do
      nil ->
        {:error, :workspace_not_found}

      ctx ->
        sweep(ctx.id)
        :ok
    end
  end

  # ── Internals ──

  # All semantic relations whose source page lives in the context. Because
  # the augmenter writes both directions from the same context, scoping by
  # source context covers the whole auto-generated layer.
  defp semantic_relations(workspace_id) do
    Repo.all(
      from r in Relation,
        join: s in Page,
        on: s.id == r.source_id,
        where: s.workspace_id == ^workspace_id,
        where: r.relation_type == "semantic",
        select: %{
          id: r.id,
          source_id: r.source_id,
          target_id: r.target_id,
          weight: r.weight,
          meta: r.meta
        }
    )
  end

  # Distance lives in `weight` for edges created by `Knowledge.auto_relate/2`
  # and in `meta["distance"]` for edges created by older augmenter versions.
  defp distance_of(%{weight: w}) when is_float(w), do: w

  defp distance_of(%{meta: meta}) when is_map(meta) do
    case Map.get(meta, "distance") do
      d when is_float(d) -> d
      d when is_integer(d) -> d * 1.0
      _ -> nil
    end
  end

  defp distance_of(_), do: nil

  defp delete_by_ids([]), do: 0

  defp delete_by_ids(ids) do
    {count, _} = Repo.delete_all(from r in Relation, where: r.id in ^ids)
    count
  end
end
