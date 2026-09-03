defmodule Dran.Repo.Migrations.CreateTaskRuns do
  use Ecto.Migration

  @moduledoc """
  `task_runs` — executions of a task step WITHIN a session (F1).

  A run is the record of one execution attempt of a plan step in a given
  session. There is always a session (decision 1): without a session a task
  simply lives on the board as today — no runs, no requirement.
  """

  def up do
    create table(:task_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :session_id,
          references(:goal_sessions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :task_id,
          references(:tasks, type: :binary_id, on_delete: :delete_all),
          null: false

      add :workspace_id,
          references(:workspaces, type: :binary_id, on_delete: :delete_all),
          null: false

      # Snapshot of `task.meta["contract"]` at run creation (nil if the
      # task has no contract) — the contract may evolve, the run records
      # what was actually executed (decision 2).
      add :contract_version, :jsonb

      add :status, :string, default: "pending", null: false

      # Summary of the result (free-form report of the executor).
      add :outcome, :string

      # Per-gate result of the verification funnel — DATA only, never
      # enforced server-side (decision 8).
      add :gate_results, :jsonb, default: "{}"

      # ✓NN durable checkpoints of the agent ledger (riel-ledger).
      add :checkpoints, :jsonb, default: "{}"

      # Who executed / the attempt number (retry = new run, attempt n+1).
      add :actor_id, references(:actors, type: :binary_id, on_delete: :nilify_all)
      add :attempt, :integer, default: 1, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:task_runs, [:session_id, :task_id, :attempt],
             name: :task_runs_session_id_task_id_attempt_index
           )

    create index(:task_runs, [:task_id], name: :task_runs_task_id_index)
    create index(:task_runs, [:workspace_id], name: :task_runs_workspace_id_index)
  end

  def down do
    drop_if_exists index(:task_runs, [:workspace_id], name: :task_runs_workspace_id_index)
    drop_if_exists index(:task_runs, [:task_id], name: :task_runs_task_id_index)

    drop_if_exists index(:task_runs, [:session_id, :task_id, :attempt],
                     name: :task_runs_session_id_task_id_attempt_index
                   )

    drop_if_exists table(:task_runs)
  end
end
