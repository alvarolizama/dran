defmodule Dran.Workflow do
  @moduledoc """
  Workflow — the execution entity: a step-by-step plan that agents RUN.

  Manual layer (goals + tasks) and execution layer (workflows) are
  independent: `goal_id` is an OPTIONAL navigation link (nullable FK),
  never a requirement. A workflow is a definition — no execution state;
  sessions/runs are the runtime (`Dran.Executions`).

  - `status` — `draft | active | archived` (single source, no redundant
    boolean — decisión ?08)
  - `kind` — `evergreen` (re-runnable, N simultaneous sessions) |
    `one_shot` (one pass)
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, read_after_writes: true}
  @foreign_key_type :binary_id

  @statuses ~w(draft active archived)
  @kinds ~w(evergreen one_shot)

  def statuses, do: @statuses
  def kinds, do: @kinds

  @derive {Jason.Encoder,
           only: [
             :id,
             :workspace_id,
             :goal_id,
             :title,
             :slug,
             :body,
             :status,
             :kind,
             :meta,
             :inserted_at,
             :updated_at
           ]}

  schema "workflows" do
    field :title, :string
    field :slug, :string
    field :body, :string, default: ""
    field :status, :string, default: "draft"
    field :kind, :string, default: "evergreen"
    field :meta, :map, default: %{}

    belongs_to :goal, Dran.Goal
    belongs_to :workspace, Dran.Workspace
    has_many :steps, Dran.Step
    has_many :sessions, Dran.WorkflowSession

    timestamps(type: :utc_datetime)
  end

  def changeset(workflow, attrs) do
    workflow
    |> cast(attrs, [
      :workspace_id,
      :goal_id,
      :title,
      :slug,
      :body,
      :status,
      :kind,
      :meta
    ])
    |> validate_required([:workspace_id, :title, :slug])
    |> validate_length(:title, max: 500)
    |> validate_length(:slug, max: 500)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:kind, @kinds)
    |> foreign_key_constraint(:goal_id)
    |> unique_constraint([:workspace_id, :slug], name: :workflows_workspace_id_slug_index)
  end
end
