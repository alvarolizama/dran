defmodule Dran.Goal do
  @moduledoc """
  First-class goal entity — the PARA QUÉ: outcome, hierarchy, and progress.

  Goals live in their own table (not as pages). Pages can link to goals
  via polymorphic `part_of` relations (`source_type: "page"`,
  `target_type: "goal"`). A plan serves a goal via `serves` relations.

  ## Progress
  - `progress` — derived (0.0–1.0) from linked tasks (`part_of`), or
    manually set when `meta["progress_manual"]` is true.
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
             :progress,
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
    field :progress, :float
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
      :progress,
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
    |> validate_progress_range()
    |> unique_constraint([:workspace_id, :slug], name: :goals_workspace_id_slug_index)
  end

  defp validate_progress_range(changeset) do
    case get_change(changeset, :progress) do
      nil ->
        changeset

      val when is_number(val) and val >= 0.0 and val <= 1.0 ->
        changeset

      _ ->
        add_error(changeset, :progress, "must be between 0.0 and 1.0")
    end
  end
end
