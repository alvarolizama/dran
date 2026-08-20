defmodule Dran.Brain.Project do
  @moduledoc """
  First-class project entity — groups goals and pages.

  Projects live in their own table (not as pages). Pages can link to projects
  via polymorphic `part_of` relations (`source_type: "page"`,
  `target_type: "project"`).

  ## Health
  Health is derived from the average of linked goals' health scores
  (green=3, yellow=2, red=1, floored). Manual override when
  `meta["health_source"]` is `"manual"`.
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
             :description,
             :body,
             :status,
             :health,
             :priority,
             :start_date,
             :target_date,
             :meta,
             :archived,
             :inserted_at,
             :updated_at
           ]}

  @statuses ~w(draft active on_hold done archived)
  @healths ~w(green yellow red)
  @priorities ~w(low medium high urgent)

  schema "projects" do
    field :title, :string
    field :slug, :string
    field :description, :string
    field :body, :string, default: ""
    field :status, :string, default: "active"
    field :health, :string
    field :priority, :string
    field :start_date, :date
    field :target_date, :date
    field :meta, :map, default: %{}
    field :archived, :boolean, default: false

    belongs_to :goal, Dran.Brain.Goal
    belongs_to :workspace, Dran.Brain.Workspace

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating or updating a project"
  def changeset(project, attrs) do
    project
    |> cast(attrs, [
      :workspace_id,
      :title,
      :slug,
      :description,
      :body,
      :status,
      :health,
      :priority,
      :start_date,
      :target_date,
      :meta,
      :archived,
      :goal_id
    ])
    |> validate_required([:workspace_id, :title, :slug])
    |> validate_length(:title, max: 500)
    |> validate_length(:slug, max: 500)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:health, @healths)
    |> validate_inclusion(:priority, @priorities)
    |> unique_constraint([:workspace_id, :slug], name: :projects_workspace_id_slug_index)
  end
end
