defmodule Dran.Repo.Migrations.RenameTaskStatuses do
  @moduledoc """
  Simplifies the task board to lifecycle-only columns:

      backlog → todo → in_progress → done | cancelled

  The old `this_week` and `today` columns duplicated what `due_date` already
  expresses (and worse — a task could sit in "today" while overdue). Time
  scoping becomes views over `due_date`, not board columns.

  Data mapping (single-instance, all existing rows migrated):

      tasks.status:            this_week → backlog, today → todo
      pages.meta.kanban_status: this_week → backlog, today → todo
        (legacy todo-style notes; the column predates first-class tasks)

  `down/2` is intentionally minimal: only `todo` needs mapping back (it did
  not exist before). `backlog` is valid in both worlds, so rows migrated out
  of `this_week` stay in `backlog` after a rollback — which rows were
  `this_week` is not recoverable. Acceptable for this single-instance tool.
  """

  use Ecto.Migration

  def up do
    execute "UPDATE tasks SET status = 'backlog' WHERE status = 'this_week'"
    execute "UPDATE tasks SET status = 'todo' WHERE status = 'today'"

    execute """
    UPDATE pages SET meta = jsonb_set(meta, '{kanban_status}', '"todo"'::jsonb, true)
    WHERE meta->>'kanban_status' = 'today'
    """

    execute """
    UPDATE pages SET meta = jsonb_set(meta, '{kanban_status}', '"backlog"'::jsonb, true)
    WHERE meta->>'kanban_status' = 'this_week'
    """
  end

  def down do
    execute "UPDATE tasks SET status = 'today' WHERE status = 'todo'"

    execute """
    UPDATE pages SET meta = jsonb_set(meta, '{kanban_status}', '"today"'::jsonb, true)
    WHERE meta->>'kanban_status' = 'todo'
    """
  end
end
