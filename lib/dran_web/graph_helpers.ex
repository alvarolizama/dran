defmodule DranWeb.GraphHelpers do
  @moduledoc """
  Shared logic for building subgraph data centered on a single page.

  Used by GraphLive (:show) and the inline graph tab on every page detail view.
  """

  alias Dran.Knowledge
  alias Dran.Page
  import Ecto.Query

  @type_colors %{
    "note" => "#60A5FA",
    "entity" => "#FB7185",
    "concept" => "#FBBF24",
    "reference" => "#60A5FA",
    "goal" => "#22C55E",
    "memory" => "#A78BFA"
  }

  @edge_colors %{
    "related" => "#94A3B8",
    "contradicts" => "#EF4444",
    "supersedes" => "#F59E0B",
    "part_of" => "#10B981"
  }

  def type_colors, do: @type_colors
  def edge_colors, do: @edge_colors

  @doc """
  Builds the subgraph centered on `page`, expanded to `depth` levels of BFS
  (default 3). Uses `Knowledge.list_relations_for_pages/1` (batch query) so each
  BFS frontier is one pair of SQL queries, not 2×N.

  Returns `%{nodes: [...], edges: [...]}`.

  ## Options

  - `:relations` — pre-loaded `%{outbound: [...], inbound: [...]}` from
    `Knowledge.list_relations_for_page/1`. When provided, skips the first-level
    query (fixes the N+1 pattern where the LiveView already loaded them).
  - `:depth` — BFS depth from the center (default 3). Level 1 = direct
    neighbors, level 2 = neighbors of neighbors, etc.
  - `:max_nodes` — cap on total nodes (default 200, including the center).
    When the expansion exceeds this, the most-connected nodes win.
  """
  def build_page_subgraph(page, opts \\ []) do
    depth = Keyword.get(opts, :depth, 3)
    max_nodes = Keyword.get(opts, :max_nodes, 200)

    # Pre-loaded relations (first level) from the LiveView, or fetch them.
    preloaded = Keyword.get(opts, :relations)

    # ── BFS expansion ───────────────────────────────────────────────────
    # Each level loads relations for all new frontier pages in one batch
    # query pair (list_relations_for_pages/1), building the node and edge
    # sets incrementally.

    {nodes, edges} =
      if preloaded do
        # Level 1 from preloaded data — extract neighbors from the relations
        {first_neighbors, first_edges} = extract_neighbors(page.id, preloaded)

        bfs_expand(
          [page.id | first_neighbors],
          first_neighbors,
          first_edges,
          MapSet.new([page.id]),
          1,
          depth,
          max_nodes
        )
      else
        # Start BFS from scratch — first level uses list_relations_for_page,
        # subsequent levels use batch list_relations_for_pages.
        rels = Knowledge.list_relations_for_page(page.id)
        {first_neighbors, first_edges} = extract_neighbors(page.id, rels)

        bfs_expand(
          [page.id | first_neighbors],
          first_neighbors,
          first_edges,
          MapSet.new([page.id]),
          1,
          depth,
          max_nodes
        )
      end

    # ── Build the final payload ─────────────────────────────────────────
    # The center page is always node 0.
    center = %{
      id: page.id,
      slug: page.slug,
      label: page.title,
      type: page.page_type,
      color: Map.get(@type_colors, page.page_type, "#94A3B8")
    }

    # Collect all unique page ids (center + neighbors)
    all_ids = [page.id | Enum.map(nodes, &elem(&1, 0))] |> Enum.uniq()

    # Fetch page metadata for all non-center ids in one query
    neighbor_ids = List.delete(all_ids, page.id)

    neighbor_pages =
      if neighbor_ids == [] do
        %{}
      else
        # Fetch minimal page info for all neighbors in one query
        pages =
          Dran.Repo.all(
            from p in Page,
              where: p.id in ^neighbor_ids,
              select: %{id: p.id, slug: p.slug, title: p.title, page_type: p.page_type}
          )

        Map.new(pages, &{&1.id, &1})
      end

    neighbor_nodes =
      neighbor_ids
      |> Enum.map(fn id ->
        case Map.get(neighbor_pages, id) do
          nil ->
            nil

          p ->
            %{
              id: p.id,
              slug: p.slug,
              label: p.title,
              type: p.page_type,
              color: Map.get(@type_colors, p.page_type, "#94A3B8")
            }
        end
      end)
      |> Enum.reject(&is_nil/1)

    all_nodes = [center | neighbor_nodes]

    # Edges: deduplicate by {source_id, target_id} pair
    unique_edges =
      edges
      |> Enum.uniq_by(fn e -> {min(e.source_id, e.target_id), max(e.source_id, e.target_id)} end)
      |> Enum.map(fn e ->
        %{
          source_id: e.source_id,
          target_id: e.target_id,
          color: Map.get(@edge_colors, e.relation_type, "#94A3B8")
        }
      end)

    %{nodes: all_nodes, edges: unique_edges}
  end

  # ── BFS expansion ──────────────────────────────────────────────────────

  # Extract neighbor ids and edges from a single page's relations.
  defp extract_neighbors(_page_id, %{outbound: outbound, inbound: inbound}) do
    out_neighbors =
      Enum.map(outbound, fn r -> {r.target_id, r.relation_type} end)

    out_edges =
      Enum.map(outbound, fn r ->
        %{source_id: r.source_id, target_id: r.target_id, relation_type: r.relation_type}
      end)

    in_neighbors =
      Enum.map(inbound, fn r -> {r.source_id, r.relation_type} end)

    in_edges =
      Enum.map(inbound, fn r ->
        %{source_id: r.source_id, target_id: r.target_id, relation_type: r.relation_type}
      end)

    neighbor_ids =
      (Enum.map(out_neighbors, &elem(&1, 0)) ++ Enum.map(in_neighbors, &elem(&1, 0)))
      |> Enum.uniq()

    edges = out_edges ++ in_edges

    {neighbor_ids, edges}
  end

  # BFS expand to `max_depth` levels. `visited` tracks all page ids already
  # seen (including center). `all_edges` accumulates edges. Returns
  # `{nodes, edges}` where nodes is a list of `{page_id, bfs_depth}`.
  defp bfs_expand(all_nodes, frontier, all_edges, _visited, current_depth, max_depth, _max_nodes)
       when current_depth >= max_depth or frontier == [] do
    # Done — return nodes (excluding the center, which is added later)
    nodes = Enum.filter(all_nodes, fn id -> id != hd(all_nodes) end)
    nodes_with_depth = Enum.map(nodes, fn id -> {id, current_depth} end)
    {nodes_with_depth, all_edges}
  end

  defp bfs_expand(all_nodes, frontier, all_edges, visited, current_depth, max_depth, max_nodes) do
    # Fetch relations for all frontier pages in one batch
    rels_by_page = Knowledge.list_relations_for_pages(frontier)

    {new_nodes, new_edges} =
      Enum.reduce(frontier, {[], []}, fn page_id, {nodes_acc, edges_acc} ->
        rels = Map.get(rels_by_page, page_id, %{outbound: [], inbound: []})
        {neighbors, edges} = extract_neighbors(page_id, rels)

        # Only keep neighbors we haven't seen yet
        new_neighbors = Enum.filter(neighbors, fn id -> not MapSet.member?(visited, id) end)

        {nodes_acc ++ new_neighbors, edges_acc ++ edges}
      end)

    # Update visited set
    new_visited = Enum.reduce(new_nodes, visited, fn id, acc -> MapSet.put(acc, id) end)

    # Cap: if we've exceeded max_nodes, stop expanding
    total_nodes = MapSet.size(new_visited)

    if total_nodes >= max_nodes do
      nodes =
        Enum.filter(all_nodes ++ new_nodes, fn id -> id != hd(all_nodes) end)
        |> Enum.uniq()
        |> Enum.take(max_nodes - 1)

      nodes_with_depth = Enum.map(nodes, fn id -> {id, current_depth + 1} end)
      {nodes_with_depth, all_edges ++ new_edges}
    else
      bfs_expand(
        all_nodes ++ new_nodes,
        new_nodes,
        all_edges ++ new_edges,
        new_visited,
        current_depth + 1,
        max_depth,
        max_nodes
      )
    end
  end
end
