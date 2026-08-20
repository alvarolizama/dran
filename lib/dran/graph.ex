defmodule Dran.Graph do
  @moduledoc """
  Structural graph algorithms over the relations table.

  Pure-Elixir implementations (PageRank, Label Propagation) that run
  in-memory over edges loaded via Ecto. No external dependencies.
  """

  import Ecto.Query
  alias Dran.Repo
  alias Dran.Relation

  # Authority-flow weight per relation type (single source of truth).
  @edge_weights %{
    "part_of" => 1.0,
    "embeds" => 0.8,
    "supersedes" => 0.7,
    "works_in" => 0.7,
    "has_tier" => 0.7,
    "based_in" => 0.7,
    "written_in" => 0.7,
    "built_with" => 0.7,
    "mentions" => 0.6,
    "related" => 0.5,
    "contradicts" => 0.2,
    "semantic" => 0.1
  }

  # Edge types that participate in community detection.
  @community_types ~w(part_of embeds supersedes related mentions works_in has_tier based_in written_in built_with)

  @damping 0.85
  @iterations 20
  @lp_iterations 30
  @lp_min_iter 3

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

  Joins on `pages` to scope by the source page's `workspace_id`.
  """
  @spec load_edges(binary()) :: [map()]
  def load_edges(workspace_id) do
    from(r in Relation,
      join: s in assoc(r, :source),
      where: s.workspace_id == ^workspace_id,
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
  def pagerank(workspace_id) do
    edges = load_edges(workspace_id)
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
  def refresh_pagerank(workspace_id) do
    ranks = pagerank(workspace_id)

    Enum.each(ranks, fn {page_id, score} ->
      new_meta = %{"pagerank" => Float.round(score, 6)}

      query =
        from(p in Dran.Page,
          where: p.id == ^page_id,
          update: [set: [meta: fragment("COALESCE(meta, '{}'::jsonb) || ?::jsonb", ^new_meta)]]
        )

      Repo.update_all(query, [])
    end)

    :ok
  end

  @doc """
  Detect communities via Label Propagation over typed edges.

  Treats edges as undirected for community purposes: each edge contributes
  its weight in both directions. Returns `%{page_id => community_label}`
  where labels are integers in `1..k` (k = number of detected communities).

  ## Algorithm

    1. Filter edges to community types (`community_edge?/1` excludes
       `semantic` and `contradicts`).
    2. Build undirected weighted adjacency: `adj[node][neighbor] = weight`,
       accumulating weight when multiple edges connect the same pair.
    3. Initialize each node's label to its own id.
    4. For up to `@lp_iterations` (30) iterations, each node adopts the
       label with the highest aggregate weight among its neighbors (ties
       broken by the label value via `Enum.max_by`).
    5. Early-stop: if labels stop changing after iteration `@lp_min_iter` (3),
       convergence is declared and the loop exits.
    6. Compress the final labels to consecutive integers `1..k` so the
       output is stable and small regardless of the raw label ids.

  Isolated nodes (no community edges) are not present in the adjacency
  map and therefore keep their initial self-label — each forms its own
  singleton community.

  ## Options

    * `:seed` — when provided, `:rand.seed(:exsss, seed)` is called before
      the iteration loop to make the shuffle deterministic. Useful for
      tests; production leaves it unset.

  ## Notes

  Label Propagation is non-deterministic across runs because the node
  update order is shuffled each iteration. Community *ids* are therefore
  unstable between refreshes — consumers must treat `community_id` as an
  opaque grouping key, never as a stable identity.
  """
  @spec communities(binary(), keyword()) :: %{binary() => integer()}
  def communities(workspace_id, opts \\ []) do
    if seed = Keyword.get(opts, :seed), do: :rand.seed(:exsss, seed)

    edges =
      workspace_id
      |> load_edges()
      |> Enum.filter(&community_edge?(&1.type))

    nodes = edges |> Enum.flat_map(&[&1.source, &1.target]) |> Enum.uniq()

    # Undirected weighted adjacency: adj[node][neighbor] = accumulated weight.
    # Each edge contributes its weight in both directions.
    adj =
      Enum.reduce(edges, %{}, fn e, acc ->
        acc
        |> update_in([Access.key(e.source, %{}), Access.key(e.target, 0.0)], &(&1 + e.weight))
        |> update_in([Access.key(e.target, %{}), Access.key(e.source, 0.0)], &(&1 + e.weight))
      end)

    # Initial labels: each node is its own community.
    labels = Map.new(nodes, &{&1, &1})

    final =
      Enum.reduce_while(1..@lp_iterations, labels, fn iter, acc ->
        new_labels =
          Enum.reduce(Enum.shuffle(nodes), acc, fn node, labels_acc ->
            neighbors = Map.get(adj, node, %{})

            if map_size(neighbors) == 0 do
              labels_acc
            else
              # Aggregate weight per neighbor-label, then pick the max.
              best =
                neighbors
                |> Enum.group_by(fn {n, _w} -> Map.get(labels_acc, n, n) end)
                |> Enum.map(fn {label, group} ->
                  {label, group |> Enum.map(&elem(&1, 1)) |> Enum.sum()}
                end)
                |> Enum.max_by(fn {_l, w} -> w end)
                |> elem(0)

              Map.put(labels_acc, node, best)
            end
          end)

        cond do
          # Early-stop: converged after the minimum iteration threshold.
          new_labels == acc and iter > @lp_min_iter -> {:halt, acc}
          true -> {:cont, new_labels}
        end
      end)

    # Compress raw labels to consecutive integers 1..k for stable output.
    unique_labels = final |> Map.values() |> Enum.uniq() |> Enum.sort()
    label_map = unique_labels |> Enum.with_index(1) |> Map.new()

    Map.new(final, fn {node, label} -> {node, Map.fetch!(label_map, label)} end)
  end

  @doc """
  Recompute communities for a context and persist `community_id` into each
  page's meta.

  Mirrors `refresh_pagerank/1`: uses `Repo.update_all` with a jsonb merge
  (`COALESCE(meta, '{}'::jsonb) || ?::jsonb`) to avoid triggering the
  augmenter, embeddings, broadcasts, and other update side effects.
  """
  @spec refresh_communities(binary()) :: :ok
  def refresh_communities(workspace_id) do
    workspace_id
    |> communities()
    |> Enum.each(fn {page_id, cid} ->
      new_meta = %{"community_id" => cid}

      query =
        from(p in Dran.Page,
          where: p.id == ^page_id,
          update: [set: [meta: fragment("COALESCE(meta, '{}'::jsonb) || ?::jsonb", ^new_meta)]]
        )

      Repo.update_all(query, [])
    end)

    :ok
  end

  @doc """
  Refresh PageRank for the default context (Quantum entrypoint).

  Resolves the default context slug via `Dran.Auth.default_workspace_slug/0`,
  looks it up with `Brain.get_workspace_by_slug/1`, and runs both
  `refresh_pagerank/1` and `refresh_communities/1` on the same context.
  PageRank runs first so community detection can reuse any future
  cross-signal logic; both share the same edge load. Same pattern as
  `Dran.Agent.Curator.run_scheduled/0`.
  """
  @spec refresh_all_scheduled() :: :ok | {:error, :workspace_not_found}
  def refresh_all_scheduled do
    slug = Dran.Auth.default_workspace_slug()

    case Dran.Brain.get_workspace_by_slug(slug) do
      nil ->
        {:error, :workspace_not_found}

      ctx ->
        :ok = refresh_pagerank(ctx.id)
        :ok = refresh_communities(ctx.id)
        :ok
    end
  end
end
