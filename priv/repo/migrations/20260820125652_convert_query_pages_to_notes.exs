defmodule Dran.Repo.Migrations.ConvertQueryPagesToNotes do
  use Ecto.Migration

  def up do
    # The `query` page type was removed from the codebase. Convert any
    # existing query pages to `note` (kind=answer) so they don't break the
    # page_type validation. Drop the query-only meta fields (difficulty,
    # answer_status, answered_by) and set kind to "answer".
    execute("""
    UPDATE pages
    SET page_type = 'note',
        meta = jsonb_set(meta - 'difficulty' - 'answer_status' - 'answered_by', '{kind}', '"answer"')
    WHERE page_type = 'query'
    """)
  end

  def down do
    # No-op: we can't reliably restore the original query meta.
    :ok
  end
end
