defmodule Dran.Repo.Migrations.CreateGoalSessions do
  use Ecto.Migration

  @moduledoc """
  `goal_sessions` — opt-in execution instances of a goal (the run is the
  record, not the requirement).

  A session is a single pass over the (stable, never-cloned) plan: opening
  one creates `pending` runs for every active step of the goal (F1, decision
  5). Session statuses: `in_flight / passed / failed / aborted`.
  """

  def up do
    create table(:goal_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :goal_id,
          references(:goals, type: :binary_id, on_delete: :delete_all),
          null: false

      add :workspace_id,
          references(:workspaces, type: :binary_id, on_delete: :delete_all),
          null: false

      # What instance this is ("lead Acme", "venta X") — free-form.
      add :label, :string

      # Instance-specific data of the session.
      add :context, :jsonb, default: "{}"

      add :status, :string, default: "in_flight", null: false

      # Who drives the session (nullable — human UI or anonymous API).
      add :actor_id, references(:actors, type: :binary_id, on_delete: :nilify_all)

      add :started_at, :utc_datetime
      add :finished_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:goal_sessions, [:goal_id], name: :goal_sessions_goal_id_index)
    create index(:goal_sessions, [:workspace_id], name: :goal_sessions_workspace_id_index)
  end

  def down do
    drop_if_exists index(:goal_sessions, [:workspace_id], name: :goal_sessions_workspace_id_index)
    drop_if_exists index(:goal_sessions, [:goal_id], name: :goal_sessions_goal_id_index)
    drop_if_exists table(:goal_sessions)
  end
end
