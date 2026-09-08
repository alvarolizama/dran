defmodule Dran.Repo.Migrations.DropTasks do
  @moduledoc """
  Drop the tasks domain entirely (decisión de Álvaro, 2026-09): the tasks
  table, the task_automations log table if present, and all relations with
  a task endpoint. The kanban board, /api/tasks facade and the MCP task
  tools were removed in the same change. Goals keep no derived task
  progress (by design, see Dran.Goals.Goal moduledoc).

  Destructive by design. `down` recreates the table empty; task data and
  task relations are NOT recoverable.
  """

  use Ecto.Migration

  def up do
    execute("DROP TABLE IF EXISTS task_automations")
    execute("DELETE FROM relations WHERE source_type = 'task' OR target_type = 'task'")
    execute("DROP TABLE IF EXISTS tasks")
  end

  def down do
    execute("""
    CREATE TABLE IF NOT EXISTS tasks (
      id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      workspace_id bigint NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
      title varchar(255) NOT NULL,
      slug varchar(255) NOT NULL,
      summary varchar(255),
      body text DEFAULT '',
      status varchar(255) DEFAULT 'backlog',
      priority varchar(255) DEFAULT 'medium',
      due_date date,
      recurrence varchar(255) DEFAULT 'none',
      checklist jsonb DEFAULT '[]',
      position double precision DEFAULT 0,
      archived boolean DEFAULT false,
      lock_version bigint DEFAULT 1,
      assignee_id bigint,
      assignee_actor_id uuid,
      creator_actor_id uuid,
      created_by varchar(255) DEFAULT 'system',
      updated_by varchar(255),
      inserted_at timestamp(0),
      updated_at timestamp(0)
    )
    """)

    execute(
      "CREATE UNIQUE INDEX IF NOT EXISTS tasks_workspace_id_slug_index ON tasks(workspace_id, slug)"
    )
  end
end
