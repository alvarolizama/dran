defmodule Dran.Repo.Migrations.RemoveRedundantKinds do
  use Ecto.Migration

  @moduledoc """
  Remaps meta.kind for pages that use a kind removed from the registry.

  Removed kinds and their replacements:

    note:    snippet → code, outline → template, log → journal
    entity:  brand → company
    concept: framework → pattern
    reference: docs → document, file → document, talk → interview

  Pages that already use the replacement kind are left untouched.
  Pages whose kind is nil or not in the remap table are left untouched.
  """

  # {page_type, old_kind} => new_kind
  @remap %{
    {"note", "snippet"} => "code",
    {"note", "outline"} => "template",
    {"note", "log"} => "journal",
    {"entity", "brand"} => "company",
    {"concept", "framework"} => "pattern",
    {"reference", "docs"} => "document",
    {"reference", "file"} => "document",
    {"reference", "talk"} => "interview"
  }

  def up do
    for {{page_type, old_kind}, new_kind} <- @remap do
      execute("""
      UPDATE pages
      SET meta = jsonb_set(meta, '{kind}', to_jsonb('#{new_kind}'::text))
      WHERE page_type = '#{page_type}'
        AND meta->>'kind' = '#{old_kind}'
      """)
    end
  end

  def down do
    # No-op: we cannot reliably restore the original kind because multiple
    # old kinds map to the same new kind (e.g. docs→document, file→document).
    :ok
  end
end
