defmodule Dran.Repo.Migrations.DropGoalsAndWorkflows do
  use Ecto.Migration

  def up do
    # Goals + Workflows removed as product features. Execution layer
    # (sessions/runs) and contracts existed only to serve workflows, so they
    # fall with them. Children first: runs -> sessions -> steps -> workflows,
    # then goals (self-FK parent_goal_id drops with the table).
    drop_if_exists table(:workflow_runs)
    drop_if_exists table(:workflow_sessions)
    drop_if_exists table(:workflow_steps)
    drop_if_exists table(:workflows)
    drop_if_exists table(:goals)
  end

  def down do
    # Irreversible in practice: the dropped rows are gone. Recreating the
    # empty tables would require replaying the full original DDL (see
    # 20260904120000_pivot_plans_to_workflows and earlier); not provided.
    raise "down/0 not supported for DropGoalsAndWorkflows — goals and workflows data is gone"
  end
end
