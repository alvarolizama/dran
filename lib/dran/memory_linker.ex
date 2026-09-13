defmodule Dran.MemoryLinker do
  @moduledoc """
  Derives graph relations for a stored fact at memory ingest.

  Two layers, both derived from the embedding `Dran.Memory.add/1` already
  generated for semantic dedupe (zero extra inference):

  * **`informs` (memory → page)** — the memory links to the top-k pages its
    embedding is closest to (`source_type: "memory"`, `target_type: "page"`).
  * **`semantic` (memory ↔ memory)** — the memory links to its top-k closest
    *active sibling memories* (both endpoint types `"memory"`). Only
    genuinely related facts get an edge: the dedupe bands own the high
    similarity range (≥ 0.95 duplicate, ≥ 0.88 near-duplicate — those merge,
    they don't link), so these edges connect related-but-distinct facts
    (typically 0.70–0.85 cosine). Directional at insert; the nightly sweep
    prunes by the same distance threshold as the page semantic layer.

  Design constraints:

  * **Zero inference cost** — reuses the dedupe embedding; a write without
    one simply skips linking.
  * **Bounded write volume** — hard cap of `@max_links` relations per memory
    per layer, matching the page augmenter's `k` neighbourhood.
  * **Workspace-scoped** — only pages/memories of the memory's own workspace
    are candidates, mirroring every other relation surface.
  * **Idempotent** — `Repo.insert(on_conflict: :nothing)`: re-running the
    linker (backfill, retries) never duplicates edges.

  The threshold reuses the per-workspace `semantic_threshold_long` knob
  (Settings → Automation): the most permissive of the three augmenter
  thresholds, consistent with how `Dran.Graph.Maintenance` prunes.
  """

  import Ecto.Query

  alias Dran.Repo
  alias Dran.Workspace

  # Hard cap of derived relations per memory, per layer. Same order as the
  # page augmenter's semantic neighbourhood (k = 3).
  @max_links 3

  @doc "Maximum derived relations a single memory may get, per layer."
  def max_links, do: @max_links

  @doc """
  Link `memory` to its graph neighbourhood: top-k closest pages (`informs`)
  and top-k closest active memories (`semantic`).

  Pages and memories are matched by embedding cosine distance (top-k under
  the workspace threshold). Returns `{:ok, created_count}` — relations
  actually inserted (conflicts count as 0). Memories without an embedding,
  or with no close neighbours, link nothing and return `{:ok, 0}`.
  """
  @spec link_to_pages(Dran.Memory.t()) :: {:ok, non_neg_integer()}
  def link_to_pages(%Dran.Memory{embedding: nil}), do: {:ok, 0}

  def link_to_pages(%Dran.Memory{} = memory) do
    threshold = resolve_threshold(memory.workspace_id)
    vec = Pgvector.new(memory.embedding)

    page_candidates =
      Repo.all(
        from p in Dran.Knowledge.Page,
          where:
            p.workspace_id == ^memory.workspace_id and
              p.archived == false and
              not is_nil(p.embedding),
          where: fragment("? <=> ?", p.embedding, ^vec) <= ^threshold,
          order_by: fragment("? <=> ?", p.embedding, ^vec),
          limit: ^@max_links,
          select: %{id: p.id, type: "page"}
      )

    memory_candidates =
      Repo.all(
        from m in Dran.Memory,
          where:
            m.workspace_id == ^memory.workspace_id and
              m.status == "active" and
              m.id != ^memory.id and
              not is_nil(m.embedding),
          where: fragment("? <=> ?", m.embedding, ^vec) <= ^threshold,
          order_by: fragment("? <=> ?", m.embedding, ^vec),
          limit: ^@max_links,
          select: %{id: m.id, type: "memory"}
      )

    inserts =
      Enum.map(page_candidates, fn target ->
        relation_attrs(memory.id, "memory", target.id, "page", "informs")
      end) ++
        Enum.map(memory_candidates, fn target ->
          relation_attrs(memory.id, "memory", target.id, "memory", "semantic")
        end)

    created =
      Enum.count(inserts, fn attrs ->
        case Repo.insert(Dran.Relation.changeset(%Dran.Relation{}, attrs),
               on_conflict: :nothing
             ) do
          {:ok, %Dran.Relation{id: id}} when not is_nil(id) -> true
          _ -> false
        end
      end)

    {:ok, created}
  end

  defp relation_attrs(source_id, source_type, target_id, target_type, relation_type) do
    %{
      source_id: source_id,
      source_type: source_type,
      target_id: target_id,
      target_type: target_type,
      relation_type: relation_type
    }
  end

  @doc """
  Backfill: link every active memory of a workspace (or all workspaces when
  the id is omitted). Existing relations are skipped by the unique constraint,
  so the task is resumable. Returns `{memories_seen, relations_created}`.
  """
  @spec backfill(binary() | nil) :: {non_neg_integer(), non_neg_integer()}
  def backfill(workspace_id \\ nil) do
    query =
      from m in Dran.Memory,
        where: m.status == "active" and not is_nil(m.embedding),
        select: %{id: m.id}

    query =
      if workspace_id do
        where(query, [m], m.workspace_id == ^workspace_id)
      else
        query
      end

    memories = Repo.all(query)

    # Reload one by one: embedding must come back as a Pgvector struct for
    # the fragment comparison (the select above keeps ids only).
    {seen, created} =
      Enum.reduce(memories, {0, 0}, fn %{id: id}, {seen, created} ->
        case Repo.get(Dran.Memory, id) do
          nil ->
            {seen, created}

          memory ->
            {:ok, n} = link_to_pages(memory)
            {seen + 1, created + n}
        end
      end)

    {seen, created}
  end

  # Per-workspace threshold with fallback to the global default — same
  # resolution as Dran.Graph.Maintenance.prune_semantic/2.
  defp resolve_threshold(workspace_id) do
    case Repo.get(Workspace, workspace_id) do
      %Workspace{} = ws -> Workspace.get_tuning(ws, :semantic_threshold_long)
      nil -> Dran.Settings.get("semantic_threshold_long")
    end
  end

  @doc """
  Quantum entrypoint (`memory_relink_nightly`): re-derive informs relations
  for every active memory, sweep informs/semantic edges whose memory
  endpoint is no longer active, and decay trust of never-retrieved facts.
  Returns a markdown report body following the `Dran.Jobs` log convention.
  Zero inference calls.
  """
  @spec run_scheduled() :: String.t()
  def run_scheduled do
    {seen, created} = backfill()
    swept = sweep_inactive()
    decayed = Dran.Memory.decay_trust()

    """
    # Memory re-link

    Memories seen #{seen} · informs created #{created} · stale edges swept #{swept} · trust decayed #{decayed}
    """
    |> String.trim()
  end

  # Drop derived edges whose memory endpoint is gone or superseded — on
  # EITHER side. informs edges have the memory as source; semantic
  # memory↔memory edges can have it as source or target. Superseded
  # memories are excluded from search AND from the graph's active top-100
  # nodes — any edge touching them would render against nothing.
  defp sweep_inactive do
    active_ids =
      from(m in Dran.Memory, where: m.status == "active", select: m.id)

    {source_side, _} =
      from(r in Dran.Relation,
        where:
          r.source_type == "memory" and r.relation_type in ["informs", "semantic"] and
            r.source_id not in subquery(active_ids)
      )
      |> Repo.delete_all()

    {target_side, _} =
      from(r in Dran.Relation,
        where:
          r.target_type == "memory" and r.relation_type == "semantic" and
            r.target_id not in subquery(active_ids)
      )
      |> Repo.delete_all()

    source_side + target_side
  end
end
