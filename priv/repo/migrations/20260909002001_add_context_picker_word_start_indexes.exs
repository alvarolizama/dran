defmodule Dran.Repo.Migrations.AddContextPickerWordStartIndexes do
  @moduledoc """
  Word-start type-ahead indexes for the step-editor Contexto picker.

  The picker's short-query fallback (WorkflowsLive.prefix_pages/2) runs
  `lower(title) ~ '\\m<query>'` / `lower(slug) ~ '\\m<query>'` filtered by
  workspace. Postgres can serve an anchored regex from a btree expression
  index with text_pattern_ops — without it every keystroke (250ms debounce)
  is a seq scan per workspace.

  Two partial-expression indexes, both leading on workspace_id so the
  workspace filter and the pattern match come from the same index.
  """
  use Ecto.Migration

  def change do
    create_if_not_exists(
      index(:knowledge_pages, ["workspace_id, lower(title) text_pattern_ops"],
        name: :knowledge_pages_ws_title_word_start_idx
      )
    )

    create_if_not_exists(
      index(:knowledge_pages, ["workspace_id, lower(slug) text_pattern_ops"],
        name: :knowledge_pages_ws_slug_word_start_idx
      )
    )
  end
end
