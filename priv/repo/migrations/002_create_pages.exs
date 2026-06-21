defmodule Dran.Repo.Migrations.CreatePages do
  use Ecto.Migration

  def up do
    create table(:pages, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :context_id, references(:contexts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :title, :string, size: 500, null: false
      add :slug, :string, size: 500, null: false
      add :body, :text, default: ""
      add :page_type, :string, size: 50, null: false
      add :summary, :text
      add :tags, {:array, :string}, default: []
      add :meta, :map, default: %{}
      add :kb_confidence, :string, size: 20
      add :kb_source_url, :text
      add :kb_contested, :boolean, default: false, null: false
      add :body_hash, :string, size: 64
      add :version, :integer, default: 1, null: false

      timestamps(type: :utc_datetime)
    end

    # Unique slug within context
    create unique_index(:pages, [:context_id, :slug])

    # immutable_unaccent wrapper — unaccent() is STABLE not IMMUTABLE,
    # so we wrap it to use in generated columns / expression indexes
    execute """
    CREATE OR REPLACE FUNCTION immutable_unaccent(text)
    RETURNS text AS $$
      SELECT public.unaccent('public.unaccent', $1)
    $$ LANGUAGE SQL IMMUTABLE STRICT
    """

    # FTS: generated column search_vector (spanish + unaccent)
    execute """
    ALTER TABLE pages ADD COLUMN search_vector tsvector
    GENERATED ALWAYS AS (
      to_tsvector('spanish',
        immutable_unaccent(coalesce(title, '')) || ' ' ||
        immutable_unaccent(coalesce(body, ''))
      )
    ) STORED
    """

    # FTS index (GIN for full-text search)
    create index(:pages, ["search_vector"], using: :gin, name: :pages_search_idx)

    # Fuzzy search index (trigram on unaccented title)
    execute """
    CREATE INDEX pages_trgm_idx ON pages
    USING GIN (immutable_unaccent(title) gin_trgm_ops)
    """

    # Lookup indexes
    create index(:pages, [:context_id, :slug], name: :pages_slug_idx)
    create index(:pages, [:page_type], name: :pages_type_idx)
    create index(:pages, [:tags], using: :gin, name: :pages_tags_idx)
  end

  def down do
    execute "ALTER TABLE pages DROP COLUMN IF EXISTS search_vector"
    drop table(:pages)
  end
end
