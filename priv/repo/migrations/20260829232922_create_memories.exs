defmodule Dran.Repo.Migrations.CreateMemories do
  use Ecto.Migration

  @moduledoc """
  Shared multi-agent memory store.

  Atomic facts extracted by agents (one row per fact), scoped per workspace.
  Dedupe by (workspace_id, content_hash) — re-adding the same fact returns the
  existing row (semantics from the holographic memory plugin's UNIQUE content).
  Trust score is adjusted by asymmetric feedback (+0.05 helpful / -0.10
  unhelpful) and weights hybrid search ranking.
  """

  def up do
    create table(:memories, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :workspace_id,
          references(:workspaces, type: :binary_id, on_delete: :delete_all),
          null: false

      add :content, :text, null: false
      # SHA-256 hex of normalized content — dedupe key per workspace
      add :content_hash, :string, null: false
      add :embedding, :vector, size: 1024
      add :trust_score, :real, default: 0.5, null: false
      add :helpful_count, :integer, default: 0, null: false
      add :retrieval_count, :integer, default: 0, null: false
      add :status, :string, default: "active", null: false
      add :source_session, :string
      add :created_by, :string, default: "system", null: false

      timestamps(type: :utc_datetime)
    end

    execute("""
    ALTER TABLE memories ADD COLUMN search_vector tsvector GENERATED ALWAYS AS (
      to_tsvector('spanish', immutable_unaccent(coalesce(content, '')))
    ) STORED
    """)

    # Dedupe: one fact per workspace (re-add returns the existing row)
    create unique_index(:memories, [:workspace_id, :content_hash],
             name: :memories_workspace_content_hash_idx
           )

    create index(:memories, [:workspace_id, :status], name: :memories_workspace_status_idx)

    execute("CREATE INDEX memories_search_idx ON memories USING gin (search_vector)")

    execute(
      "CREATE INDEX memories_embedding_idx ON memories USING hnsw (embedding vector_cosine_ops)"
    )
  end

  def down do
    execute("DROP INDEX IF EXISTS memories_embedding_idx")
    execute("DROP INDEX IF EXISTS memories_search_idx")

    drop_if_exists(
      index(:memories, [:workspace_id, :status], name: :memories_workspace_status_idx)
    )

    drop_if_exists(
      index(:memories, [:workspace_id, :content_hash], name: :memories_workspace_content_hash_idx)
    )

    execute("ALTER TABLE memories DROP COLUMN IF EXISTS search_vector")
    drop table(:memories)
  end
end
