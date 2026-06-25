defmodule Dran.Repo.Migrations.CreateAgentSessions do
  use Ecto.Migration

  def change do
    create table(:agent_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :context_id, references(:contexts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :agent_type, :string, null: false
      add :input, :string, null: false
      add :status, :string, default: "pending", null: false
      add :summary, :text
      add :pages_created, :integer, default: 0
      add :steps_count, :integer, default: 0
      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime
      add :meta, :map, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:agent_sessions, [:context_id])
    create index(:agent_sessions, [:agent_type])
    create index(:agent_sessions, [:status])

    create table(:agent_steps, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :session_id, references(:agent_sessions, type: :binary_id, on_delete: :delete_all),
        null: false

      add :step_number, :integer, null: false
      add :tool_name, :string, null: false
      add :tool_args, :map, default: %{}
      add :tool_result, :map, default: %{}
      add :reasoning, :text

      timestamps(type: :utc_datetime)
    end

    create index(:agent_steps, [:session_id])
    create index(:agent_steps, [:session_id, :step_number])
  end
end
