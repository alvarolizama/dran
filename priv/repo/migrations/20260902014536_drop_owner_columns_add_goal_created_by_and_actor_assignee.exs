defmodule Dran.Repo.Migrations.DropOwnerColumnsAddGoalCreatedByAndActorAssignee do
  use Ecto.Migration

  @moduledoc """
  Phase 2 of the actor model: identity consolidation.

  * `pages.owner` and `tasks.owner` are DROPPED — they duplicated
    `created_by` with weaker guarantees (client-settable until phase 1).
    Historical owner values equal to created_by in ~all rows; the filters
    and UI that read `owner` were removed in the same wave.
  * `goals.created_by` + `goals.updated_by` — goals had no attribution at
    all; same convention as tasks (server-side from the actor).
  * `tasks.assignee_actor_id` → `actors` — an agent can now be assigned a
    task (the old `assignee_id` pointed at `users` only). The old column is
    kept (nullable, historical data); new writes go to the actor FK.
  """

  def up do
    alter table(:goals) do
      add :created_by, :string, default: "system", null: false
      add :updated_by, :string
    end

    alter table(:tasks) do
      add :assignee_actor_id,
          references(:actors, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:tasks, [:assignee_actor_id], name: :tasks_assignee_actor_id_index)

    alter table(:pages) do
      remove :owner
    end

    alter table(:tasks) do
      remove :owner
    end
  end

  def down do
    alter table(:tasks) do
      add :owner, :string, default: "system"
    end

    alter table(:pages) do
      add :owner, :string, default: "system", null: false
    end

    drop_if_exists(index(:tasks, [:assignee_actor_id], name: :tasks_assignee_actor_id_index))

    alter table(:tasks) do
      remove :assignee_actor_id
    end

    alter table(:goals) do
      remove :updated_by
      remove :created_by
    end
  end
end
