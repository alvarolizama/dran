defmodule Dran.Graph.ClusterSummary do
  @moduledoc """
  A persisted natural-language summary for a detected graph cluster.

  Once cluster detection stamps each page's `meta["cluster_id"]`,
  `Dran.Graph.ClusterSummaries` produces a 2-3 sentence summary per cluster
  and stores it here alongside the highest-ranked pages, so the GraphRAG layer
  can retrieve an overview of a cluster without re-querying the LLM.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, read_after_writes: true}
  @foreign_key_type :binary_id

  schema "cluster_summaries" do
    field :cluster_id, :integer
    field :summary, :string
    field :page_count, :integer, default: 0
    field :top_pages, {:array, :map}, default: []
    field :generated_at, :utc_datetime

    belongs_to :workspace, Dran.Workspace

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating or updating a cluster summary."
  def changeset(summary, attrs) do
    summary
    |> cast(attrs, [
      :workspace_id,
      :cluster_id,
      :summary,
      :page_count,
      :top_pages,
      :generated_at
    ])
    |> validate_required([:workspace_id, :cluster_id, :summary, :generated_at])
    |> unique_constraint([:workspace_id, :cluster_id])
  end
end
