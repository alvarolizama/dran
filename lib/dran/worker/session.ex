defmodule Dran.Worker.Session do
  @moduledoc """
  Generic session schema for every Dran worker run.

  A session tracks the worker type, input, current status, summary,
  counters, and metadata. It owns a collection of `Dran.Worker.Step`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Dran.Worker.Step
  alias Dran.Workspace

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "worker_sessions" do
    field :worker_type, :string
    field :input, :string
    field :status, :string, default: "pending"
    field :summary, :string
    field :pages_created, :integer, default: 0
    field :steps_count, :integer, default: 0
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime
    field :meta, :map, default: %{}

    belongs_to :workspace, Workspace
    has_many :steps, Step

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :worker_type,
      :input,
      :status,
      :summary,
      :pages_created,
      :steps_count,
      :started_at,
      :completed_at,
      :meta,
      :workspace_id
    ])
    |> validate_required([:worker_type, :input, :workspace_id])
    |> validate_inclusion(:status, ~w(pending running done failed cancelled))
  end
end
