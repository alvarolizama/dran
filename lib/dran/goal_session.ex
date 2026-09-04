defmodule Dran.GoalSession do
  @moduledoc """
  Opt-in execution instance of a goal — one pass over the (stable,
  never-cloned) plan.

  A session exists only when someone opens it (`Dran.Executions.open_session/2`);
  without a session everything works exactly as today (the run is the record,
  not the requirement). A goal can have several sessions, even simultaneous —
  each with its own context.

  Statuses: `in_flight / passed / failed / aborted`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, read_after_writes: true}
  @foreign_key_type :binary_id

  @session_statuses ~w(in_flight passed failed aborted)

  schema "goal_sessions" do
    field :label, :string
    field :context, :map, default: %{}
    field :status, :string, default: "in_flight"
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime

    # Frozen definition the session runs against (wave B):
    # %{"steps" => [%{"id", "title", "contract"}], "edges" => [[from, to]]}.
    field :plan_snapshot, :map, default: %{}

    belongs_to :plan, Dran.Plan
    belongs_to :goal, Dran.Goal
    belongs_to :workspace, Dran.Workspace
    belongs_to :actor, Dran.Actors.Actor

    has_many :runs, Dran.TaskRun, foreign_key: :session_id

    timestamps(type: :utc_datetime)
  end

  @doc "List of valid session statuses"
  def session_statuses, do: @session_statuses

  @doc "Build a changeset for a goal session"
  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :plan_id,
      :goal_id,
      :workspace_id,
      :plan_snapshot,
      :label,
      :context,
      :status,
      :actor_id,
      :started_at,
      :finished_at
    ])
    |> validate_required([:plan_id, :goal_id, :workspace_id, :status])
    |> validate_inclusion(:status, @session_statuses)
    |> foreign_key_constraint(:plan_id)
    |> foreign_key_constraint(:goal_id)
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:actor_id)
  end

  @doc "Is the session still open (runs can be added/closed)?"
  def open?(%__MODULE__{status: status}), do: status == "in_flight"

  @doc "Is the session closed (terminal state)?"
  def closed?(%__MODULE__{status: status}), do: status in ["passed", "failed", "aborted"]
end
