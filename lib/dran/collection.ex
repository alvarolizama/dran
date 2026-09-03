defmodule Dran.Collection do
  @moduledoc """
  Saved filter query — replaces the old Smart Collection pattern
  (query pages with `meta.query`).

  Collections live in their own table and store their filter criteria
  in the `filters` JSONB column.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, read_after_writes: true}
  @foreign_key_type :binary_id

  @derive {Jason.Encoder,
           only: [
             :id,
             :workspace_id,
             :name,
             :slug,
             :summary,
             :filters,
             :inserted_at,
             :updated_at
           ]}

  schema "collections" do
    field :name, :string
    field :slug, :string
    field :summary, :string
    field :filters, :map, default: %{}

    belongs_to :workspace, Dran.Workspace

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating or updating a collection"
  def changeset(collection, attrs) do
    collection
    |> cast(attrs, [:workspace_id, :name, :slug, :summary, :filters])
    |> validate_required([:workspace_id, :name, :slug])
    |> validate_length(:name, max: 500)
    |> validate_length(:slug, max: 500)
    |> unique_constraint([:workspace_id, :slug], name: :collections_workspace_id_slug_index)
  end
end
