defmodule Dran.Agent.Step do
  @moduledoc """
  Generic step schema for every Dran agent run.

  Each step records one tool invocation, its arguments, the result,
  and optional reasoning produced by the agent.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Dran.Agent.Session

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agent_steps" do
    field :step_number, :integer
    field :tool_name, :string
    field :tool_args, :map, default: %{}
    field :tool_result, :map, default: %{}
    field :reasoning, :string

    belongs_to :session, Session

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(step, attrs) do
    step
    |> cast(attrs, [
      :step_number,
      :tool_name,
      :tool_args,
      :tool_result,
      :reasoning,
      :session_id
    ])
    |> validate_required([:step_number, :tool_name, :session_id])
  end
end
