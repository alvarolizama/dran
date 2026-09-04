defmodule Dran.Plan do
  @moduledoc """
  First-class plan entity — the definition of HOW: an ordered set of steps
  plus `depends_on` edges between them (plans/steps/tasks model, wave A).

  Plans live in their own table (`plans`), not as pages. A plan is served to
  goals via `serves` relations (`source_type: "plan"`, `target_type: "goal"`);
  steps belong to it via the structural `plan_id` FK. Plan-level links to
  knowledge pages use the same polymorphic `relations` as everything else.

  Definition only: no status, no board, no execution state — that lives in
  sessions/runs (wave B+).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, read_after_writes: true}
  @foreign_key_type :binary_id

  @derive {Jason.Encoder,
           only: [
             :id,
             :workspace_id,
             :title,
             :slug,
             :summary,
             :body,
             :meta,
             :inserted_at,
             :updated_at
           ]}

  schema "plans" do
    field :title, :string
    field :slug, :string
    field :summary, :string
    field :body, :string, default: ""
    field :meta, :map, default: %{}

    belongs_to :workspace, Dran.Workspace
    has_many :steps, Dran.Step

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating or updating a plan"
  def changeset(plan, attrs) do
    plan
    |> cast(attrs, [:workspace_id, :title, :slug, :summary, :body, :meta])
    |> validate_required([:workspace_id, :title, :slug])
    |> validate_length(:title, max: 500)
    |> validate_length(:slug, max: 500)
    |> unique_constraint([:workspace_id, :slug], name: :plans_workspace_id_slug_index)
  end
end
