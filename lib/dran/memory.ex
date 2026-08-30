defmodule Dran.Memory do
  @moduledoc """
  Shared multi-agent memory: atomic facts per workspace, with content dedupe,
  asymmetric trust feedback, and trust-weighted hybrid search.

  The memory layer is deliberately separate from `Dran.Page`:

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
    |> cast(attrs, [:workspace_id, :content, :status, :source_session, :created_by])
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

  Generates the embedding synchronously when inference is configured; on
  embedding failure the memory is still stored (embedding nil) — losing a
  fact over a degraded embedding service is worse than reduced recall.

  Returns:
    * `{:ok, memory, :created}` — new fact stored
    * `{:ok, existing, :duplicate}` — fact already existed (row untouched)
  """
  def add(attrs) do
    content = Map.fetch!(attrs, "content")
    ws_id = Map.fetch!(attrs, "workspace_id")
    hash = content_hash(content)

    # Explicit dedupe first — cheap read beats a constraint race, and the
    # unique_constraint in the changeset catches the true insert race.
    case Repo.get_by(__MODULE__, workspace_id: ws_id, content_hash: hash) do
      %__MODULE__{} = existing ->
        {:ok, existing, :duplicate}

      nil ->
        %__MODULE__{}
        |> changeset(attrs)
        |> maybe_put_embedding()
        |> Repo.insert()
        |> case do
          {:ok, memory} ->
            {:ok, memory, :created}

          {:error, %Ecto.Changeset{errors: [{:content_hash, _} | _]}} ->
            {:ok, Repo.get_by!(__MODULE__, workspace_id: ws_id, content_hash: hash), :duplicate}

          {:error, reason} ->
            {:error, reason}
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
  Trust-weighted hybrid search: FTS (spanish tsvector) + semantic (pgvector
  cosine) fused with Reciprocal Rank Fusion, final score multiplied by
  trust_score. Superseded memories are excluded. Bumps retrieval_count of
  the returned facts.
  """
  def search(workspace_id, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
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

    bump_retrieval(ids)

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
    from(m in __MODULE__,
      where:
        m.workspace_id == ^workspace_id and
          m.status == "active" and
          fragment("search_vector @@ plainto_tsquery('spanish', ?)", ^query),
      order_by: fragment("ts_rank(search_vector, plainto_tsquery('spanish', ?)) DESC", ^query),
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
    from(m in __MODULE__, where: m.workspace_id == ^workspace_id)
    |> maybe_filter_status(Keyword.get(opts, :status))
    |> order_by(desc: :inserted_at)
    |> Repo.all()
    |> maybe_paginate(Keyword.get(opts, :limit), Keyword.get(opts, :offset))
  end

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, status), do: where(query, [m], m.status == ^status)

  defp maybe_paginate(memo, nil, nil), do: memo

  defp maybe_paginate(memo, limit, offset) do
    memo
    |> Enum.drop(offset || 0)
    |> Enum.take(limit || 10_000)
  end

  def get_memory!(id), do: Repo.get!(__MODULE__, id)

  def get_memory(id), do: Repo.get(__MODULE__, id)

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
  end
end
