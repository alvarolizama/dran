defmodule Dran.Repo.Migrations.AddEmbeddingToPages do
  use Ecto.Migration

  def up do
    alter table(:pages) do
      add :embedding_hash, :string
      add :embedding, :vector, size: 1024
    end

    execute "CREATE INDEX pages_embedding_idx ON pages USING hnsw (embedding vector_cosine_ops)"
  end

  def down do
    execute "DROP INDEX IF EXISTS pages_embedding_idx"

    alter table(:pages) do
      remove :embedding
      remove :embedding_hash
    end
  end
end
