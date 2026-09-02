defmodule Dran.Repo.Migrations.AddCreatorActorIdToTasks do
  use Ecto.Migration

  @moduledoc """
  F6 of the resource standardization: every write is attributed to the
  acting actor BY ID, not by the legacy name-matching convention
  (`created_by == actor.name`). `created_by` (string) is kept as the
  human-readable mirror for display and API responses.
  """

  def change do
    alter table(:tasks) do
      add :creator_actor_id, references(:actors, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:tasks, [:creator_actor_id], name: :tasks_creator_actor_id_index)
  end
end
