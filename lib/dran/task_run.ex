defmodule Dran.TaskRun do
  @moduledoc """
  One execution attempt of a task step WITHIN a session.

  The run is the record, not the requirement: a task does not need a run to
  be done (simple human tasks live on the board as today). When a task runs
  inside a session, the execution leaves a `TaskRun` — `pending` is created
  upfront when the session opens, and the executor moves it through
  `in_flight → passed | failed | skipped` via
  `Dran.Executions.start_run/1` / `close_run/2`. A retry is a new run of the
  same `(session_id, task_id)` with `attempt: n + 1`.

  Statuses: `pending / in_flight / passed / failed / skipped`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, read_after_writes: true}
  @foreign_key_type :binary_id

  @run_statuses ~w(pending in_flight passed failed skipped)

  schema "task_runs" do
    field :contract_version, :map
    field :status, :string, default: "pending"
    field :outcome, :string
    field :gate_results, :map, default: %{}
    field :checkpoints, :map, default: %{}
    field :attempt, :integer, default: 1

    belongs_to :session, Dran.GoalSession, foreign_key: :session_id
    belongs_to :task, Dran.Task
    belongs_to :workspace, Dran.Workspace
    belongs_to :actor, Dran.Actors.Actor

    timestamps(type: :utc_datetime)
  end

  @doc "List of valid run statuses"
  def run_statuses, do: @run_statuses

  @doc "Build a changeset for a task run"
  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :session_id,
      :task_id,
      :workspace_id,
      :contract_version,
      :status,
      :outcome,
      :gate_results,
      :checkpoints,
      :actor_id,
      :attempt
    ])
    |> validate_required([:session_id, :task_id, :workspace_id])
    |> validate_required([:status])
    |> validate_inclusion(:status, @run_statuses)
    |> validate_number(:attempt, greater_than: 0)
    |> foreign_key_constraint(:session_id)
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:actor_id)
    |> unique_constraint([:session_id, :task_id, :attempt],
      name: :task_runs_session_id_task_id_attempt_index
    )
  end

  @doc "Is the run finished (terminal state)?"
  def finished?(%__MODULE__{status: status}), do: status in ["passed", "failed", "skipped"]

  @doc "Is the run still open (pending or in_flight)?"
  def open?(%__MODULE__{status: status}), do: status in ["pending", "in_flight"]
end
