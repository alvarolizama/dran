defmodule Dran.Repo.Migrations.CreateTasks do
  use Ecto.Migration

  @moduledoc """
  First-class tasks table — replaces notes with kind:"todo" + the kanban
  columns that lived in `pages`.

  Tasks are independent entities: they exist standalone by default. Links to
  goals and pages are opt-in via polymorphic `relations` (W2 adds "task" to
  the node types). No goal_slug/plan_slug/project_slug in meta — relations
  are the only linking mechanism.

  Subtasks are a checklist inside `meta` (decision: lightweight, not queried
  individually): `meta.checklist => [%{text: "...", done: false}, ...]`.
  """

  @statuses ~w(backlog this_week today in_progress done cancelled)
  @priorities ~w(low medium high urgent)
  @recurrences ~w(none daily weekly monthly)

  def up do
    create table(:tasks, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :workspace_id,
          references(:workspaces, type: :binary_id, on_delete: :delete_all),
          null: false

      add :title, :string, null: false
      add :slug, :string, null: false
      add :body, :text, default: ""
      add :summary, :string

      add :status, :string, default: "backlog", null: false
      add :priority, :string
      add :position, :integer, default: 0, null: false
      add :due_date, :date

      # assignee FK to users (users table uses serial PK, not binary_id)
      add :assignee_id, references(:users, on_delete: :nilify_all)

      add :meta, :jsonb, default: "{}"
      add :recurrence, :string, default: "none", null: false

      add :lock_version, :integer, default: 1, null: false
      add :completed_at, :utc_datetime

      add :archived, :boolean, default: false, null: false

      # Owner tracking (same convention as pages/goals)
      add :owner, :string, default: "system"
      add :created_by, :string, default: "system"
      add :updated_by, :string
      add :on_behalf_of, :string

      timestamps(type: :utc_datetime)
    end

    # Board query: WHERE workspace AND status ORDER BY position
    create index(:tasks, [:workspace_id, :status, :position], name: :tasks_board_index)

    # Filter by assignee
    create index(:tasks, [:workspace_id, :assignee_id], name: :tasks_assignee_index)

    # Slug lookup
    create unique_index(:tasks, [:workspace_id, :slug], name: :tasks_workspace_id_slug_index)

    # Due-date / SLA queries
    create index(:tasks, [:workspace_id, :due_date], name: :tasks_due_date_index)

    # Recurrence sweep — partial index on recurring tasks only
    create index(:tasks, [:recurrence, :completed_at],
             name: :tasks_recurrence_index,
             where: "recurrence != 'none'"
           )
  end

  def down do
    drop_if_exists index(:tasks, :tasks_recurrence_index)
    drop_if_exists index(:tasks, :tasks_due_date_index)
    drop_if_exists index(:tasks, :tasks_workspace_id_slug_index)
    drop_if_exists index(:tasks, :tasks_assignee_index)
    drop_if_exists index(:tasks, :tasks_board_index)
    drop_if_exists table(:tasks)
  end
end
