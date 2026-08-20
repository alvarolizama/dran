defmodule Dran.Graph.CommunitySummary do
  @moduledoc """
  A persisted natural-language summary for a detected graph community.

  Once community detection stamps each page's `meta["community_id"]`,
  `Dran.Graph.CommunitySummaries` produces a 2-3 sentence summary per community
  and stores it here alongside the highest-ranked pages, so the GraphRAG layer
  can retrieve an overview of a community without re-querying the LLM.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, read_after_writes: true}
  @foreign_key_type :binary_id

  schema "community_summaries" do
    field :community_id, :integer
    field :summary, :string
    field :page_count, :integer, default: 0
    field :top_pages, {:array, :map}, default: []
    field :generated_at, :utc_datetime

    belongs_to :workspace, Dran.Brain.Workspace

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating or updating a community summary."
  def changeset(summary, attrs) do
    summary
    |> cast(attrs, [
      :workspace_id,
      :community_id,
      :summary,
      :page_count,
      :top_pages,
      :generated_at
    ])
    |> validate_required([:workspace_id, :community_id, :summary, :generated_at])
    |> unique_constraint([:workspace_id, :community_id])
  end
end
