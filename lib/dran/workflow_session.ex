defmodule Dran.WorkflowSession do
  @moduledoc """
  An execution instance of a workflow — one pass over the (stable,
  never-cloned) definition, frozen into `snapshot` at open time.

  A session exists only when someone opens it
  (`Dran.Executions.open_session/2`). An evergreen workflow can have
  several sessions, even simultaneous — each with its own context. The
  goal link is optional (denormalized from `workflow.goal_id` at open
  time, used only for display).

  Snapshot shape: `%{\"steps\" => [%{\"id\", \"title\", \"contract\"}],
  \"edges\" => [[from, to]]}` — same as the wave A backfill.

  Statuses: `in_flight / passed / failed / aborted`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, read_after_writes: true}
  @foreign_key_type :binary_id

  @session_statuses ~w(in_flight passed failed aborted)

  schema "workflow_sessions" do
    field :label, :string
    field :context, :map, default: %{}
    field :status, :string, default: "in_flight"
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime

    # Frozen definition the session runs against:
    # %{\"steps\" => [%{\"id\", \"title\", \"contract\"}], \"edges\" => [[from, to]]}.
    field :snapshot, :map, default: %{}

    belongs_to :workflow, Dran.Workflow
    belongs_to :goal, Dran.Goal
    belongs_to :workspace, Dran.Workspace
    belongs_to :actor, Dran.Actors.Actor

    has_many :runs, Dran.Run, foreign_key: :session_id

    timestamps(type: :utc_datetime)
  end

  @doc "List of valid session statuses"
  def session_statuses, do: @session_statuses

  @doc "Build a changeset for a workflow session"
  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :workflow_id,
      :goal_id,
      :workspace_id,
      :snapshot,
      :label,
      :context,
      :status,
      :actor_id,
      :started_at,
      :finished_at
    ])
    |> validate_required([:workflow_id, :workspace_id, :status])
    |> validate_inclusion(:status, @session_statuses)
    |> foreign_key_constraint(:workflow_id)
    |> foreign_key_constraint(:goal_id)
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:actor_id)
  end

  @doc "Is the session still open (runs can be started/closed)?"
  def open?(%__MODULE__{status: status}), do: status == "in_flight"

  @doc "Is the session closed (terminal state)?"
  def closed?(%__MODULE__{status: status}), do: status in ["passed", "failed", "aborted"]
end
