defmodule Dran.Goal do
  @moduledoc """
  First-class goal entity — the PARA QUÉ: outcome and hierarchy.

  Goals live in their own table (not as pages). Pages can link to goals
  via polymorphic `part_of` relations (`source_type: "page"`,
  `target_type: "goal"`); tasks link the same way. Goals carry NO
  derived progress — the execution layer (workflows/sessions/runs)
  never writes back here.
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
             :status,
             :team,
             :meta,
             :archived,
             :created_by,
             :updated_by,
             :inserted_at,
             :updated_at
           ]}

  @statuses ~w(draft active on_hold done archived)

  schema "goals" do
    field :title, :string
    field :slug, :string
    field :summary, :string
    field :body, :string, default: ""
    field :status, :string, default: "active"
    field :team, {:array, :string}, default: []
    field :meta, :map, default: %{}
    field :archived, :boolean, default: false

    # Attribution — resolves server-side from the actor (Dran.Actors)
    field :created_by, :string, default: "system"
    field :updated_by, :string

    belongs_to :parent_goal, Dran.Goal
    belongs_to :workspace, Dran.Workspace

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating or updating a goal"
  def changeset(goal, attrs) do
    goal
    |> cast(attrs, [
      :workspace_id,
      :title,
      :slug,
      :summary,
      :body,
      :status,
      :team,
      :meta,
      :archived,
      :created_by,
      :updated_by,
      :parent_goal_id
    ])
    |> validate_required([:workspace_id, :title, :slug])
    |> validate_length(:title, max: 500)
    |> validate_length(:slug, max: 500)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:workspace_id, :slug], name: :goals_workspace_id_slug_index)
  end
end
