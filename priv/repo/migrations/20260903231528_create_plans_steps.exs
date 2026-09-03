defmodule Dran.Repo.Migrations.CreatePlansSteps do
  use Ecto.Migration

  @moduledoc """
  Plans and steps as first-class definition entities (plans/steps/tasks model,
  wave A — see .spike/plans-steps-tasks-design.md).

  * `plans` — the CÓMO: an ordered set of steps + `depends_on` edges between
    them, served to goals via `serves` relations. Definition only: no status,
    no board.
  * `steps` — definition nodes of a plan: title, body (the brief), contract
    in `meta["contract"]`, manual `position` for ordering. The plan of a step
    is structural (one and only one) → direct `plan_id` FK, NOT a polymorphic
    relation. Step→step `depends_on` edges stay in `relations`.

  Both use the same conventions as goals/tasks: binary_id PKs with
  gen_random_uuid() defaults, unique `(workspace_id, slug)`,
  utc_datetime timestamps.
  """

  def up do
    create table(:plans, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :workspace_id,
          references(:workspaces, type: :binary_id, on_delete: :delete_all),
          null: false

      add :title, :string, null: false
      add :slug, :string, null: false
      add :summary, :string
      add :body, :text, default: ""
      add :meta, :jsonb, default: "{}"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:plans, [:workspace_id, :slug], name: :plans_workspace_id_slug_index)
    create index(:plans, [:workspace_id], name: :plans_workspace_id_index)

    create table(:steps, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :workspace_id,
          references(:workspaces, type: :binary_id, on_delete: :delete_all),
          null: false

      add :plan_id,
          references(:plans, type: :binary_id, on_delete: :delete_all),
          null: false

      add :title, :string, null: false
      add :slug, :string, null: false
      add :body, :text, default: ""
      add :position, :integer, default: 0, null: false
      add :meta, :jsonb, default: "{}"

      timestamps(type: :utc_datetime)
    end

    create index(:steps, [:plan_id, :position], name: :steps_plan_id_position_index)
    create unique_index(:steps, [:workspace_id, :slug], name: :steps_workspace_id_slug_index)
  end

  def down do
    # New-type relations (serves/instance_of between plan/step endpoints and
    # step→step depends_on) have no FK to these tables — delete them before
    # dropping so the rollback leaves no dangling polymorphic rows.
    execute("""
    DELETE FROM relations
    WHERE relation_type IN ('serves', 'instance_of')
       OR (relation_type = 'depends_on' AND
           source_type = 'step' AND target_type = 'step')
    """)

    # Indexes go down with the tables; drop-if-exists keeps fresh/prod DBs
    # whose down runs only once agnostic of name drift.
    drop_if_exists index(:steps, [:workspace_id, :slug], name: :steps_workspace_id_slug_index)
    drop_if_exists index(:steps, [:plan_id, :position], name: :steps_plan_id_position_index)
    drop table(:steps)

    drop_if_exists index(:plans, [:workspace_id], name: :plans_workspace_id_index)
    drop_if_exists index(:plans, [:workspace_id, :slug], name: :plans_workspace_id_slug_index)
    drop table(:plans)
  end
end
