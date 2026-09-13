defmodule Dran.Repo.Migrations.MemoriesMultilangFtsAndGreyzone do
  use Ecto.Migration

  @moduledoc """
  Language-neutral FTS for memories.

  The original generated column used `to_tsvector('spanish', ...)`: facts
  stored in English (or any non-Spanish language) were only retrievable via
  the semantic path — if embeddings were down, they were invisible. Holographic
  (Hermes' local memory provider) uses SQLite FTS5 `unicode61`, which is
  language-neutral: tokenize + unaccent, no language-specific stemming.

  Same posture here: `simple` config (no stemmer) + immutable_unaccent.
  Recall quality is carried by the semantic path and RRF fusion; FTS only
  needs exact-ish token overlap across languages.
  """

  def up do
    execute("DROP INDEX IF EXISTS memories_search_idx")

    execute("""
    ALTER TABLE memories DROP COLUMN IF EXISTS search_vector
    """)

    execute("""
    ALTER TABLE memories ADD COLUMN search_vector tsvector GENERATED ALWAYS AS (
      to_tsvector('simple', immutable_unaccent(coalesce(content, '')))
    ) STORED
    """)

    execute("CREATE INDEX memories_search_idx ON memories USING gin (search_vector)")
  end

  def down do
    execute("DROP INDEX IF EXISTS memories_search_idx")

    execute("""
    ALTER TABLE memories DROP COLUMN IF EXISTS search_vector
    """)

    execute("""
    ALTER TABLE memories ADD COLUMN search_vector tsvector GENERATED ALWAYS AS (
      to_tsvector('spanish', immutable_unaccent(coalesce(content, '')))
    ) STORED
    """)

    execute("CREATE INDEX memories_search_idx ON memories USING gin (search_vector)")
  end
end
