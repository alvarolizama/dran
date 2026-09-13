defmodule Dran.Memory do
  @moduledoc """
  Shared multi-agent memory: atomic facts per workspace, with content dedupe,
  asymmetric trust feedback, and trust-weighted hybrid search.

  The memory layer is deliberately separate from `Dran.Knowledge.Page`:

  * content is exact and immutable (no LLM augmentation rewrites facts)
  * write-hot, no inference call per fact (embedding only)
  * trust/retrieval counters are first-class columns, not meta JSONB

  Attribution: `created_by` records which agent stored the fact (injected
  server-side from the API key by the REST controller — never client-set).

  ## Dedupe

  `add/1` is idempotent per workspace: a fact whose normalized content was
  already stored returns `{:ok, existing, :duplicate}` without modifying the
  row (same semantics as the holographic memory plugin's UNIQUE constraint).

  ## Trust

  Feedback is asymmetric — helpful: +0.05, unhelpful: −0.10, clamped to
  [0.0, 1.0] — and `search/3` multiplies relevance by trust so useful facts
  surface first in the shared store.
  """

  use Ecto.Schema
  import Ecto.Query
  import Ecto.Changeset

  alias Dran.Repo

  @primary_key {:id, :binary_id, read_after_writes: true}
  @foreign_key_type :binary_id

  @derive {Jason.Encoder,
           only: [
             :id,
             :workspace_id,
             :content,
             :trust_score,
             :helpful_count,
             :retrieval_count,
             :status,
             :source_session,
             :created_by,
             :inserted_at,
             :updated_at
           ]}

  @statuses ~w(active superseded)

  # Trust feedback: +0.05 helpful / −0.10 unhelpful, clamped to [0, 1]
  # (pinned by MemoryTest). Compile-time constant statements — the only
  # runtime parameter is the row id.
  @feedback_helpful_sql "UPDATE memories SET trust_score = least(1.0, greatest(0.0, trust_score + 0.05)), " <>
                          "helpful_count = helpful_count + 1, updated_at = NOW() WHERE id = $1"

  @feedback_unhelpful_sql "UPDATE memories SET trust_score = least(1.0, greatest(0.0, trust_score - 0.10)), " <>
                            "updated_at = NOW() WHERE id = $1"

  schema "memories" do
    field :content, :string
    field :content_hash, :string
    field :embedding, Pgvector.Ecto.Vector
    field :trust_score, :float, default: 0.5
    field :helpful_count, :integer, default: 0
    field :retrieval_count, :integer, default: 0
    field :status, :string, default: "active"
    field :source_session, :string
    field :created_by, :string, default: "system"
    # search_vector is a Postgres generated column — not mapped in Ecto.

    belongs_to :workspace, Dran.Workspace

    timestamps(type: :utc_datetime)
  end

  @doc false
  def statuses, do: @statuses

  @doc "Normalized content: trimmed, whitespace collapsed, lowercased for hashing."
  def normalize_content(content) when is_binary(content) do
    content
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
  end

  def content_hash(content) when is_binary(content) do
    :crypto.hash(:sha256, normalize_content(content))
    |> Base.encode16(case: :lower)
  end

  @doc false
  def changeset(memory, attrs) do
    memory
    |> cast(attrs, [:workspace_id, :content, :status, :source_session, :created_by, :trust_score])
    |> validate_required([:workspace_id, :content])
    |> update_change(:content, &normalize_content/1)
    |> validate_length(:content, min: 1)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:content_hash, name: :memories_workspace_content_hash_idx)
    |> put_content_hash()
  end

  defp put_content_hash(changeset) do
    case get_change(changeset, :content) do
      nil -> changeset
      content -> put_change(changeset, :content_hash, content_hash(content))
    end
  end

  @doc """
  Store a fact in the workspace's shared memory. Idempotent per content.

  Dedupe is three-tier: exact content hash first (cheap), then semantic in
  two bands — cosine similarity >= `@semantic_dupe_threshold` returns
  `{:ok, existing, :duplicate}` (row untouched), while the grey zone
  [`@near_dupe_threshold`, `@semantic_dupe_threshold`) returns
  `{:ok, existing, :near_duplicate}` without storing. The caller decides
  what to do: refine the existing fact (`update/2`), or re-call `add/1`
  with `force: true` to store it as a genuinely different fact.
  Cross-language rewordings land in the grey zone instead of piling up
  as near-identical active rows.

  Generates the embedding synchronously when inference is configured; on
  embedding failure the memory is still stored (embedding nil) — losing a
  fact over a degraded embedding service is worse than reduced recall.

  Returns:
    * `{:ok, memory, :created}` — new fact stored
    * `{:ok, existing, :duplicate}` — fact already existed (row untouched)
    * `{:ok, existing, :near_duplicate}` — grey zone; nothing was stored
    * `{:error, reason}` — validation or storage failure
  """
  # 1 - cosine distance; catches "same fact, different wording" (hash misses it).
  @semantic_dupe_threshold 0.95
  # Cross-language rewordings and partial overlaps: same fact family, not
  # provably identical. Too aggressive to auto-merge, too close to ignore.
  @near_dupe_threshold 0.88

  def add(attrs, opts \\ [])

  def add(attrs, opts) do
    content = Map.fetch!(attrs, "content")
    ws_id = Map.fetch!(attrs, "workspace_id")
    hash = content_hash(content)
    force? = Keyword.get(opts, :force, false)

    # Explicit dedupe first — cheap read beats a constraint race, and the
    # unique_constraint in the changeset catches the true insert race.
    case Repo.get_by(__MODULE__, workspace_id: ws_id, content_hash: hash) do
      %__MODULE__{} = existing ->
        {:ok, existing, :duplicate}

      nil ->
        changeset =
          %__MODULE__{}
          |> changeset(attrs)
          |> maybe_put_embedding()

        # Semantic dedupe AFTER embedding generation: needs the candidate vector.
        cond do
          force? ->
            insert_memory(changeset, ws_id, hash)

          true ->
            case semantic_match(changeset, ws_id) do
              {:duplicate, %__MODULE__{} = existing} ->
                {:ok, existing, :duplicate}

              {:near_duplicate, %__MODULE__{} = existing} ->
                {:ok, existing, :near_duplicate}

              nil ->
                insert_memory(changeset, ws_id, hash)
            end
        end
    end
  end

  defp insert_memory(changeset, ws_id, hash) do
    changeset
    |> Repo.insert()
    |> case do
      {:ok, memory} ->
        # Graph presence: derive informs relations to the closest
        # pages. Best-effort — a linking failure must never fail the
        # write (same posture as the augmenter's entity linking).
        _ = Dran.MemoryLinker.link_to_pages(memory)
        broadcast_memory_change(memory.workspace_id, :created, memory)
        {:ok, memory, :created}

      {:error, %Ecto.Changeset{errors: [{:content_hash, _} | _]}} ->
        {:ok, Repo.get_by!(__MODULE__, workspace_id: ws_id, content_hash: hash), :duplicate}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Closest active embedding in two similarity bands (1 - cosine distance):
  # >= 0.95 → :duplicate; >= 0.88 → :near_duplicate (grey zone); else nil.
  defp semantic_match(changeset, workspace_id) do
    case get_change(changeset, :embedding) do
      nil ->
        nil

      vec ->
        # Bands are SIMILARITY >= 0.88/0.95; pgvector gives cosine DISTANCE
        # (1 - similarity). Prefilter with the near-duplicate distance so
        # only rows inside the wider band reach the SQL-side classification.
        near_distance = 1.0 - @near_dupe_threshold

        from(m in __MODULE__,
          where:
            m.workspace_id == ^workspace_id and m.status == "active" and
              not is_nil(m.embedding),
          where: fragment("? <=> ? <= ?", m.embedding, ^vec, ^near_distance),
          order_by: fragment("? <=> ?", m.embedding, ^vec),
          limit: 1,
          select: {m, fragment("1 - (? <=> ?)", m.embedding, ^vec)}
        )
        |> Repo.one()
        |> case do
          nil ->
            nil

          {%__MODULE__{} = m, similarity} ->
            if similarity >= @semantic_dupe_threshold do
              {:duplicate, m}
            else
              {:near_duplicate, m}
            end
        end
    end
  end

  @doc """
  Update a fact in place (Holographic `update` semantics): rewrite content,
  re-embed, and keep the row's earned trust — trust_score, helpful_count and
  retrieval_count survive the rewrite. Broadcasts `:updated`.

  The row must be active; updating a superseded fact is an error. Embedding
  failures keep the old embedding (a degraded inference service must not
  block a correction).
  """
  def update_memory(%__MODULE__{status: "superseded"}, _content), do: {:error, :superseded}

  def update_memory(%__MODULE__{} = memory, content) when is_binary(content) do
    normalized = normalize_content(content)

    if normalized == memory.content do
      {:ok, memory}
    else
      changeset =
        memory
        |> change(content: normalized, content_hash: content_hash(normalized))
        |> maybe_reembed(memory)

      case Repo.update(changeset) do
        {:ok, updated} ->
          broadcast_memory_change(updated.workspace_id, :updated, updated)
          {:ok, updated}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp maybe_reembed(changeset, _memory) do
    case get_change(changeset, :content) do
      nil ->
        changeset

      new_content ->
        if Dran.Inference.enabled?() do
          # On failure keep the old embedding — a degraded inference
          # service must not block a content correction.
          case Dran.Inference.embed(new_content) do
            {:ok, vec} -> put_change(changeset, :embedding, vec)
            _ -> changeset
          end
        else
          changeset
        end
    end
  end

  defp maybe_put_embedding(changeset) do
    content = get_change(changeset, :content)

    if is_binary(content) and Dran.Inference.enabled?() do
      case Dran.Inference.embed(content) do
        {:ok, vector} -> put_change(changeset, :embedding, vector)
        _ -> changeset
      end
    else
      changeset
    end
  end

  @doc """
  Record asymmetric feedback on a fact: +0.05 helpful / −0.10 unhelpful,
  clamped to [0.0, 1.0]. Atomic single UPDATE.
  """
  def record_feedback(id, helpful?) when is_boolean(helpful?) do
    case Ecto.UUID.dump(id) do
      {:ok, uuid_bin} ->
        result =
          if helpful? do
            Repo.query(@feedback_helpful_sql, [uuid_bin])
          else
            Repo.query(@feedback_unhelpful_sql, [uuid_bin])
          end

        case result do
          {:ok, %Postgrex.Result{num_rows: 0}} -> {:error, :not_found}
          {:ok, %Postgrex.Result{}} -> {:ok, Repo.get!(__MODULE__, id)}
          {:error, reason} -> {:error, reason}
        end

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Decay trust of never-retrieved memories (nightly hygiene, holographic-style).

  Active memories older than `@decay_min_age_days` whose `retrieval_count`
  is 0 lose `@decay_step` trust per elapsed 30-day window (clamped at
  `@trust_floor`). Feedback-earned trust is untouched: only facts that were
  never retrieved AND never rated fade. Returns the number of rows updated.
  """
  @decay_min_age_days 30
  @decay_step 0.02
  @decay_floor 0.15

  def decay_trust do
    cutoff = DateTime.add(DateTime.utc_now(), -@decay_min_age_days * 24, :hour)

    {count, _} =
      from(m in __MODULE__,
        where:
          m.status == "active" and m.retrieval_count == 0 and
            m.helpful_count == 0 and
            m.trust_score > @decay_floor and
            m.inserted_at < ^cutoff,
        update: [
          set: [
            trust_score:
              fragment(
                "greatest(?, ? - (floor(extract(epoch from (now() - ?)) / 2592000.0) - ?) * ?)",
                ^@decay_floor,
                m.trust_score,
                m.inserted_at,
                ^(@decay_min_age_days / 30.0),
                ^@decay_step
              ),
            updated_at: fragment("now()")
          ]
        ]
      )
      |> Repo.update_all([])

    count
  end

  @doc """
  Trust-weighted hybrid search: FTS (language-neutral `simple` + unaccent)
  + semantic (pgvector cosine) fused with Reciprocal Rank Fusion, final
  score multiplied by trust_score. Superseded memories are excluded. Bumps
  retrieval_count of the returned facts.
  """
  def search(workspace_id, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    bump? = Keyword.get(opts, :bump_retrieval, true)
    fts = fts_candidates(workspace_id, query, limit)
    semantic = semantic_candidates(workspace_id, query, limit)

    fused =
      %{}
      |> fuse(fts)
      |> fuse(semantic)
      |> Map.new(fn {id, %{score: score, memory: m}} ->
        {id, %{memory: m, relevance: score, score: score * m.trust_score}}
      end)
      |> Enum.sort_by(fn {_id, %{score: s}} -> s end, :desc)
      |> Enum.take(limit)

    ids = Enum.map(fused, fn {id, _} -> id end)

    if bump?, do: bump_retrieval(ids)

    by_id = Map.new(fused, fn {id, %{score: score}} -> {id, score} end)

    from(m in __MODULE__, where: m.id in ^ids)
    |> Repo.all()
    |> Enum.map(fn m -> %{memory: m, score: Map.fetch!(by_id, m.id)} end)
    |> Enum.sort_by(fn %{score: score} -> score end, :desc)
  end

  defp fuse(acc, ranked) do
    ranked
    |> Enum.with_index(1)
    |> Enum.reduce(acc, fn {m, rank}, acc ->
      score = 1.0 / (60 + rank)
      existing = Map.get(acc, m.id, %{score: 0.0, memory: m})
      Map.put(acc, m.id, %{memory: m, score: existing.score + score})
    end)
  end

  defp fts_candidates(workspace_id, query, limit) do
    # 'simple' + unaccent: language-neutral token match (see migration
    # MemoriesMultilangFtsAndGreyzone). Cross-language recall is carried by
    # the semantic candidates; FTS handles exact-ish token overlap.
    from(m in __MODULE__,
      where:
        m.workspace_id == ^workspace_id and
          m.status == "active" and
          fragment("search_vector @@ plainto_tsquery('simple', ?)", ^query),
      order_by: fragment("ts_rank(search_vector, plainto_tsquery('simple', ?)) DESC", ^query),
      limit: ^limit
    )
    |> Repo.all()
  end

  defp semantic_candidates(workspace_id, query, limit) do
    if Dran.Inference.enabled?() do
      case Dran.Inference.embed(query) do
        {:ok, vec} ->
          from(m in __MODULE__,
            where:
              m.workspace_id == ^workspace_id and m.status == "active" and not is_nil(m.embedding),
            order_by: fragment("? <=> ?", m.embedding, ^vec),
            limit: ^limit
          )
          |> Repo.all()

        _ ->
          []
      end
    else
      []
    end
  end

  defp bump_retrieval([]), do: :ok

  defp bump_retrieval(ids) do
    from(m in __MODULE__, where: m.id in ^ids)
    |> Repo.update_all(inc: [retrieval_count: 1])

    :ok
  end

  @doc "List memories of a workspace, newest first. Opts: :status, :limit, :offset."
  def list_memories(workspace_id, opts \\ []) do
    # limit/offset push down to SQL (LIMIT/OFFSET) — paginating in memory
    # would load the workspace's whole memories table on every call.
    from(m in __MODULE__, where: m.workspace_id == ^workspace_id)
    |> maybe_filter_status(Keyword.get(opts, :status))
    # Tiebreak by id so offset pagination is deterministic even when two
    # facts land in the same second (multi-agent REST ingest).
    |> order_by(desc: :inserted_at, desc: :id)
    |> limit(^Keyword.get(opts, :limit))
    |> offset(^Keyword.get(opts, :offset))
    |> Repo.all()
  end

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, status), do: where(query, [m], m.status == ^status)

  def get_memory!(id), do: Repo.get!(__MODULE__, id)

  @doc "Count active memories of a workspace (sidebar badge)."
  def count_memories(workspace_id) do
    from(m in __MODULE__, where: m.workspace_id == ^workspace_id and m.status == "active")
    |> Repo.aggregate(:count)
  end

  @doc """
  Related-fact snapshots for a batch of memories: the other endpoint of
  each semantic memory↔memory edge, grouped by source id.

  Returns `%{memory_id => [%{id: id, content: content}, ...]}` — active
  neighbours only, one query for the whole batch. Powers the "related
  facts" row in the memory UI; the graph renders the same edges as 3D
  links between memory nodes.
  """
  def related_snapshots(workspace_id, ids) when is_list(ids) do
    from(r in Dran.Relation,
      join: m in __MODULE__,
      on:
        (r.source_id == m.id and r.target_id in ^ids and r.source_type == "memory" and
           r.target_type == "memory") or
          (r.target_id == m.id and r.source_id in ^ids and r.source_type == "memory" and
             r.target_type == "memory"),
      where:
        r.relation_type == "semantic" and m.workspace_id == ^workspace_id and
          m.status == "active",
      select: {r.source_id, r.target_id, m.id, m.content}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn {src, tgt, neighbor_id, content}, acc ->
      # The edge is stored directionally (latest → earlier); the UI shows it
      # from both ends, so attribute the neighbour to whichever side matches.
      acc
      |> maybe_put_neighbor(src, ids, neighbor_id, content)
      |> maybe_put_neighbor(tgt, ids, neighbor_id, content)
    end)
  end

  defp maybe_put_neighbor(acc, endpoint, batch_ids, neighbor_id, content) do
    # `endpoint` is IN the batch (the card being rendered) when the neighbour
    # is the other side; skip when the endpoint is the neighbour itself.
    if endpoint in batch_ids and endpoint != neighbor_id do
      Map.update(acc, endpoint, [%{id: neighbor_id, content: content}], fn list ->
        [%{id: neighbor_id, content: content} | list]
      end)
    else
      acc
    end
  end

  # UI notification: MemoryLive refreshes on {:memory_changed, action, memory}.
  # Dedicated topic (NOT brain:<workspace_id>): that shared topic is received
  # by older LiveViews whose handle_info has no catch-all, so an unexpected
  # message type would crash them. One topic per message family is the safe
  # contract. GraphCache invalidation keeps the workspace graph in sync —
  # memories are additive graph nodes.
  defp broadcast_memory_change(workspace_id, action, memory) do
    Phoenix.PubSub.broadcast(
      Dran.PubSub,
      "memory:#{workspace_id}",
      {:memory_changed, action, memory}
    )

    Dran.GraphCache.invalidate_context(workspace_id)
    :ok
  rescue
    # PubSub/ETS may not be running during release tasks (bin/dran eval, seeds)
    # where only the repo is started — the broadcast is a UI notification and
    # must never fail the write (same rescue as Knowledge.broadcast_page_change).
    _ -> :ok
  end

  @doc """
  Fetch a memory scoped to its workspace. Returns nil when the id does not
  exist OR belongs to another workspace — callers must not distinguish the
  two cases (row-level authorization for API keys with per-workspace scope).
  """
  def get_scoped_memory(_id, nil), do: nil

  def get_scoped_memory(id, workspace_id) do
    case Ecto.UUID.dump(workspace_id) do
      {:ok, _} -> Repo.get_by(__MODULE__, id: id, workspace_id: workspace_id)
      :error -> nil
    end
  end

  @doc "Soft-removes a fact from circulation (excluded from search)."
  def delete_memory(%__MODULE__{} = memory) do
    memory
    |> change(status: "superseded")
    |> Repo.update()
    |> tap(fn
      {:ok, updated} -> broadcast_memory_change(memory.workspace_id, :deleted, updated)
      _ -> :ok
    end)
  end

  @doc """
  Permanently deletes a fact (hard DELETE — the row is gone, not superseded).

  Drops the memory's `informs` relations in the same call: relations are
  polymorphic (no FK), so leaving them would orphan edges pointing at a
  deleted row. Returns `{:ok, memory}` (the deleted struct, for the
  broadcast payload) or `{:error, :not_deleted}`.
  """
  def purge_memory(%__MODULE__{} = memory) do
    with {:ok, deleted} <- Repo.delete(memory) do
      delete_memory_relations(memory.id)
      broadcast_memory_change(memory.workspace_id, :purged, deleted)
      {:ok, deleted}
    else
      {:error, _} -> {:error, :not_deleted}
    end
  end

  @doc """
  Permanently deletes every superseded (obsolete) fact of a workspace.

  Returns `{count, nil}` — the number of rows hard-deleted. Does NOT touch
  active facts. Also sweeps the `informs` relations of the purged rows
  (polymorphic endpoints have no FK to cascade).
  """
  def purge_superseded(workspace_id) do
    ids =
      from(m in __MODULE__,
        where: m.workspace_id == ^workspace_id and m.status == "superseded",
        select: m.id
      )
      |> Repo.all()

    {count, _} =
      from(m in __MODULE__, where: m.workspace_id == ^workspace_id and m.status == "superseded")
      |> Repo.delete_all()

    Enum.each(ids, &delete_memory_relations/1)

    if count > 0, do: broadcast_memory_change(workspace_id, :purged, nil)
    {count, nil}
  end

  # Polymorphic relations have no FK: a purged memory's derived edges must be
  # swept explicitly on BOTH sides or they dangle forever. informs edges have
  # the memory as source; semantic memory↔memory edges can have it as target.
  defp delete_memory_relations(memory_id) do
    from(r in Dran.Relation,
      where:
        (r.source_id == ^memory_id and r.source_type == "memory") or
          (r.target_id == ^memory_id and r.target_type == "memory")
    )
    |> Repo.delete_all()

    :ok
  end
end
