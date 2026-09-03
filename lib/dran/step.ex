defmodule Dran.Step do
  @moduledoc """
  First-class step entity — a DEFINITION node of a plan (plans/steps/tasks
  model, wave A).

  The step defines WHAT, in what order, and how it is verified: `title`,
  `body` (the brief) and the contract in `meta["contract"]` (same shape as
  `task.meta["contract"]` today). It is never executed itself — no board
  status, no due_date, no assignee: that is the task/run layer (wave B+).

  The plan of a step is structural (one and only one) → direct `plan_id` FK,
  not a polymorphic relation. Step→step `depends_on` edges live in
  `relations`. `position` orders steps within the plan (manual, gap-based).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, read_after_writes: true}
  @foreign_key_type :binary_id

  @derive {Jason.Encoder,
           only: [
             :id,
             :workspace_id,
             :plan_id,
             :title,
             :slug,
             :body,
             :position,
             :meta,
             :inserted_at,
             :updated_at
           ]}

  schema "steps" do
    field :title, :string
    field :slug, :string
    field :body, :string, default: ""
    field :position, :integer, default: 0
    field :meta, :map, default: %{}

    belongs_to :workspace, Dran.Workspace
    belongs_to :plan, Dran.Plan

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating or updating a step"
  def changeset(step, attrs) do
    step
    |> cast(attrs, [:workspace_id, :plan_id, :title, :slug, :body, :position, :meta])
    |> validate_required([:workspace_id, :plan_id, :title, :slug])
    |> validate_length(:title, max: 500)
    |> validate_length(:slug, max: 500)
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> unique_constraint([:workspace_id, :slug], name: :steps_workspace_id_slug_index)
  end
end