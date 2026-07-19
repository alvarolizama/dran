defmodule Dran.Graph do
  @moduledoc """
  Structural graph algorithms over the relations table.

  Pure-Elixir implementations (PageRank, Label Propagation) that run
  in-memory over edges loaded via Ecto. No external dependencies.
  """

  import Ecto.Query
  alias Dran.Repo
  alias Dran.Brain.Relation

  # Authority-flow weight per relation type (single source of truth).
  @edge_weights %{
    "part_of" => 1.0,
    "embeds" => 0.8,
    "supersedes" => 0.7,
    "related" => 0.5,
    "contradicts" => 0.2,
    "semantic" => 0.1
  }

  # Edge types that participate in community detection.
  @community_types ~w(part_of embeds supersedes related)

  @damping 0.85
  @iterations 20

  @doc "Authority-flow weight for a relation type. Unknown types default to 0.5."
  @spec edge_weight(String.t() | atom()) :: float()
  def edge_weight(type) when is_atom(type), do: edge_weight(Atom.to_string(type))
  def edge_weight(type), do: Map.get(@edge_weights, type, 0.5)

  @doc "Whether an edge type participates in community detection."
  @spec community_edge?(String.t() | atom()) :: boolean()
  def community_edge?(type) when is_atom(type), do: community_edge?(Atom.to_string(type))
  def community_edge?(type), do: type in @community_types

  @doc """
  Load all edges for a context as a list of
  `%{source: id, target: id, type: type, weight: typed_weight}`.

  Joins on `pages` to scope by the source page's `context_id`.
  """
  @spec load_edges(binary()) :: [map()]
  def load_edges(context_id) do
    from(r in Relation,
      join: s in assoc(r, :source),
      where: s.context_id == ^context_id,
      select: %{source: r.source_id, target: r.target_id, type: r.relation_type}
    )
    |> Repo.all()
    |> Enum.map(fn e -> Map.put(e, :weight, edge_weight(e.type)) end)
  end

  @doc """
  Weighted PageRank over the context graph.

  Returns a normalized map `%{page_id => score}` where scores sum to 1.
  Outbound weight is split proportionally by typed edge weight, so
  `part_of` transfers more authority than `semantic`.

  Implementation notes (see plan Task 1.3):

  For each iteration, every node receives from each of its inbound edges a
  share of the source's current score proportional to the edge's weight
  relative to the source's total outbound weight:

      share = src_score * (e.weight / total_weight_of_source)

  The per-source total outbound weight is precomputed in `out_links` (the
  `total_weight` field) so the inner loop only looks up a single scalar
  rather than re-summing the outbound list each time. Dangling nodes (no
  outbound edges) redistribute their score uniformly across all nodes to
  avoid leaking rank out of the system. Scores are renormalized to sum to
  1 after the final iteration.
  """
  @spec pagerank(binary()) :: %{binary() => float()}
  def pagerank(context_id) do
    edges = load_edges(context_id)
    nodes = edges |> Enum.flat_map(&[&1.source, &1.target]) |> Enum.uniq()

    case nodes do
      [] ->
        %{}

      _ ->
        n = length(nodes)
        base = (1.0 - @damping) / n

        # out_links[src] = %{targets: [{target, ratio}], total_weight: sum}
        # where ratio = e.weight / total_weight_of_source.
        out_links =
          Enum.group_by(edges, & &1.source)
          |> Map.new(fn {src, outs} ->
            total = Enum.sum(Enum.map(outs, & &1.weight))
            targets = Enum.map(outs, fn o -> {o.target, o.weight / total} end)
            {src, %{targets: targets, total_weight: total}}
          end)

        initial = Map.new(nodes, &{&1, 1.0 / n})

        ranks =
          Enum.reduce(1..@iterations, initial, fn _i, acc ->
            # Sum contributions into each target node.
            incoming =
              Enum.reduce(edges, %{}, fn e, m ->
                src_score = Map.get(acc, e.source, 0.0)
                src_total = out_links[e.source].total_weight
                share = src_score * (e.weight / src_total)
                Map.update(m, e.target, share, &(&1 + share))
              end)

            # Redistribute dangling mass (nodes with no outbound edges).
            dangling_mass =
              nodes
              |> Enum.filter(fn node -> not Map.has_key?(out_links, node) end)
              |> Enum.reduce(0.0, fn node, sum -> sum + Map.get(acc, node, 0.0) end)

            dangling_share = dangling_mass / n

            Map.new(nodes, fn node ->
              incoming_score = Map.get(incoming, node, 0.0)
              {node, base + @damping * (incoming_score + dangling_share)}
            end)
          end)

        total = Enum.sum(Map.values(ranks))

        if total > 0 do
          Map.new(ranks, fn {k, v} -> {k, v / total} end)
        else
          ranks
        end
    end
  end

  @doc """
  Recompute PageRank for a context and persist scores into each page's meta.

  Uses `Repo.update_all` with a jsonb merge (`COALESCE(meta, '{}'::jsonb) || ?`)
  rather than `Brain.update_page/2` to avoid triggering the augmenter,
  embeddings, broadcasts, and other update side effects. Scores are rounded
  to 6 decimal places to keep meta clean.
  """
  @spec refresh_pagerank(binary()) :: :ok
  def refresh_pagerank(context_id) do
    ranks = pagerank(context_id)

    Enum.each(ranks, fn {page_id, score} ->
      new_meta = %{"pagerank" => Float.round(score, 6)}

      query =
        from(p in Dran.Brain.Page,
          where: p.id == ^page_id,
          update: [set: [meta: fragment("COALESCE(meta, '{}'::jsonb) || ?::jsonb", ^new_meta)]]
        )

      Repo.update_all(query, [])
    end)

    :ok
  end

  @doc """
  Refresh PageRank for the default context (Quantum entrypoint).

  Resolves the default context slug via `Dran.Auth.default_context_slug/0`,
  looks it up with `Brain.get_context_by_slug/1`, and runs
  `refresh_pagerank/1`. Same pattern as `Dran.Agent.Curator.run_scheduled/0`.
  """
  @spec refresh_all_scheduled() :: :ok | {:error, :context_not_found}
  def refresh_all_scheduled do
    slug = Dran.Auth.default_context_slug()

    case Dran.Brain.get_context_by_slug(slug) do
      nil -> {:error, :context_not_found}
      ctx -> refresh_pagerank(ctx.id)
    end
  end
end
