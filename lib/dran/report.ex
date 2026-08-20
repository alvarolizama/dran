defmodule Dran.Report do
  @moduledoc """
  System-created report entity — lint outputs, community summaries,
  job results, etc.

  Reports live in their own table. They are second-citizen entities
  (no graph, no journey, no embeddings).
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
             :body,
             :report_type,
             :meta,
             :archived,
             :inserted_at,
             :updated_at
           ]}

  @report_types ~w(log lint community_summary agent_output)

  schema "reports" do
    field :title, :string
    field :slug, :string
    field :body, :string, default: ""
    field :report_type, :string, default: "log"
    field :meta, :map, default: %{}
    field :archived, :boolean, default: false

    belongs_to :workspace, Dran.Workspace

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating or updating a report"
  def changeset(report, attrs) do
    report
    |> cast(attrs, [:workspace_id, :title, :slug, :body, :report_type, :meta, :archived])
    |> validate_required([:workspace_id, :title, :slug])
    |> validate_length(:title, max: 500)
    |> validate_length(:slug, max: 500)
    |> validate_inclusion(:report_type, @report_types)
    |> unique_constraint([:workspace_id, :slug], name: :reports_workspace_id_slug_index)
  end
end
