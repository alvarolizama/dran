defmodule Dran.Repo.Migrations.ConvertComparisonPagesToNotes do
  use Ecto.Migration

  def up do
    # The `comparison` page type was removed from the codebase. Convert any
    # existing comparison pages to `note` so they don't break the
    # page_type validation.
    execute("""
    UPDATE pages
    SET page_type = 'note',
        meta = meta || '{"kind": "thought"}'::jsonb
    WHERE page_type = 'comparison'
    """)
  end

  def down do
    # No-op: we can't reliably restore the original comparison meta.
    :ok
  end
end
