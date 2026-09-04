defmodule Dran.Run do
  @moduledoc """
  One execution attempt of a STEP within a session — the ONLY runtime.

  Runs are created upfront (all `pending`) when the session opens, keyed
  by `(session_id, step_id, attempt)`. A retry is a new run of the same
  `(session_id, step_id)` with `attempt: n + 1`. No task is ever spawned:
  the manual layer (board) and the execution layer never mix.

  - `contract_version` — the step's `meta[\"contract\"]` frozen at open
    time (nil when the step has no contract).
  - `progress` — phase-level progress reported by the agent (overwrite,
    not append): `%{\"phase\" => \"…\", \"gates\" => %{…}}`. The history
    lives in `gate_results` at close (decisión ?02).
  - `outcome` + `gate_results` — the executor's terminal report (DATA,
    never enforced server-side).

  Statuses: `pending / in_flight / passed / failed / skipped`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, read_after_writes: true}
  @foreign_key_type :binary_id

  @run_statuses ~w(pending in_flight passed failed skipped)

  schema "runs" do
    field :contract_version, :map
    field :status, :string, default: "pending"
    field :outcome, :string
    field :gate_results, :map, default: %{}
    field :checkpoints, :map, default: %{}
    field :progress, :map, default: %{}
    field :attempt, :integer, default: 1

    belongs_to :session, Dran.WorkflowSession, foreign_key: :session_id
    belongs_to :step, Dran.Step
    belongs_to :workspace, Dran.Workspace
    belongs_to :actor, Dran.Actors.Actor

    timestamps(type: :utc_datetime)
  end

  @doc "List of valid run statuses"
  def run_statuses, do: @run_statuses

  @doc "Build a changeset for a run"
  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :session_id,
      :step_id,
      :workspace_id,
      :contract_version,
      :status,
      :outcome,
      :gate_results,
      :checkpoints,
      :progress,
      :actor_id,
      :attempt
    ])
    |> validate_required([:session_id, :step_id, :workspace_id])
    |> validate_required([:status])
    |> validate_inclusion(:status, @run_statuses)
    |> validate_number(:attempt, greater_than: 0)
    |> foreign_key_constraint(:session_id)
    |> foreign_key_constraint(:step_id)
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:actor_id)
    |> unique_constraint([:session_id, :step_id, :attempt],
      name: :runs_session_id_step_id_attempt_index
    )
  end

  @doc "Is the run finished (terminal state)?"
  def finished?(%__MODULE__{status: status}), do: status in ["passed", "failed", "skipped"]

  @doc "Is the run still open (pending or in_flight)?"
  def open?(%__MODULE__{status: status}), do: status in ["pending", "in_flight"]
end
