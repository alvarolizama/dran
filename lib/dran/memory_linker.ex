defmodule Dran.MemoryLinker do
  @moduledoc """
  Derives `informs` relations (memory → page) at memory ingest.

  A stored fact gains graph presence by linking to the pages its embedding is
  closest to: for each new memory with an embedding, the workspace's pages are
  ranked by cosine distance and the top-k pages under a threshold get an
  `informs` relation (`source_type: "memory"`, `target_type: "page"`).

  Design constraints:

  * **Zero inference cost** — reuses the embedding `Dran.Memory.add/1` already
    generated for semantic dedupe; a write without one simply skips linking.
  * **Bounded write volume** — hard caps of `@max_links` page links plus
    `@max_links` propagated goal links per memory (≤ 6 relations total),
    matching the page augmenter's `k` neighbourhood.
  * **Workspace-scoped** — only pages of the memory's own workspace are
    candidates, mirroring every other relation surface.
  * **Idempotent** — `Repo.insert(on_conflict: :nothing)`: re-running the
    linker (backfill, retries) never duplicates edges.

  The threshold reuses the per-workspace `semantic_threshold_long` knob
  (Settings → Automation): the most permissive of the three augmenter
  thresholds, consistent with how `Dran.Graph.Maintenance` prunes.
  """

  import Ecto.Query

  alias Dran.Repo
  alias Dran.Workspace

  # Hard cap of informs relations per memory. Same order as the page
  # augmenter's semantic neighbourhood (k = 3).
  @max_links 3

  @doc "Maximum informs relations a single memory may derive."
  def max_links, do: @max_links

  @doc """
  Link `memory` to its top-k semantically closest pages, and through them to
  their goals.

  Pages are matched by embedding cosine distance (top-k under the workspace
  threshold). Goals have no embedding, so they inherit: a memory that informs
  a page `part_of` a goal also informs that goal — a memory about "ship the
  auth flow" lands on the auth goal through the auth pages. Returns
  `{:ok, created_count}` — relations actually inserted (conflicts count as
  0). Memories without an embedding, or with no close pages, link nothing
  and return `{:ok, 0}`.
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

    # Goals have NO embedding column — semantic matching is impossible
    # without extra inference per goal (violates the zero-cost constraint).
    # Instead: propagate transitively. A memory that informs a page which is
    # `part_of` a goal also informs that goal — zero extra queries beyond
    # one relation lookup over the linked pages, bounded by @max_links.
    linked_page_ids = Enum.map(page_candidates, & &1.id)

    goal_candidates =
      if linked_page_ids == [] do
        []
      else
        Repo.all(
          from r in Dran.Relation,
            where:
              r.source_id in ^linked_page_ids and r.source_type == "page" and
                r.relation_type == "part_of" and r.target_type == "goal",
            distinct: true,
            limit: ^@max_links,
            select: %{id: r.target_id, type: "goal"}
        )
      end

    created =
      Enum.count(page_candidates ++ goal_candidates, fn %{id: target_id, type: target_type} ->
        case Repo.insert(
               Dran.Relation.changeset(%Dran.Relation{}, %{
                 source_id: memory.id,
                 source_type: "memory",
                 target_id: target_id,
                 target_type: target_type,
                 relation_type: "informs"
               }),
               on_conflict: :nothing
             ) do
          {:ok, %Dran.Relation{id: id}} when not is_nil(id) -> true
          _ -> false
        end
      end)

    {:ok, created}
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
  for every active memory, then sweep informs edges whose memory is no
  longer active (superseded rows keep their edges until purged — but they
  must stop pointing at graph targets). Returns a markdown report body
  following the `Dran.Jobs` log convention. Zero inference calls.
  """
  @spec run_scheduled() :: String.t()
  def run_scheduled do
    {seen, created} = backfill()
    swept = sweep_inactive()

    """
    # Memory re-link

    Memories seen #{seen} · informs created #{created} · stale informs swept #{swept}
    """
    |> String.trim()
  end

  # Drop informs edges whose source memory is gone or superseded. Superseded
  # memories are excluded from search AND from the graph's active top-100
  # nodes — their edges would render against nothing.
  defp sweep_inactive do
    {count, _} =
      from(r in Dran.Relation,
        join: m in Dran.Memory,
        on: r.source_id == m.id and r.source_type == "memory",
        where: r.relation_type == "informs" and m.status != "active"
      )
      |> Repo.delete_all()

    # Edges whose memory row vanished entirely (should not happen — purge
    # sweeps them — but a manual SQL delete would orphan them).
    {orphans, _} =
      from(r in Dran.Relation,
        where:
          r.source_type == "memory" and r.relation_type == "informs" and
            r.source_id not in subquery(
              from m in Dran.Memory,
                where: m.status == "active",
                select: m.id
            )
      )
      |> Repo.delete_all()

    count + orphans
  end
end
