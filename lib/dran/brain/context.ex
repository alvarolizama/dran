defmodule Dran.Brain.Context do
  @moduledoc """
  A context is an isolated silo of knowledge (personal, work, projects).
  All pages and relations belong to a context.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, read_after_writes: true}
  @foreign_key_type :binary_id

  @derive {Jason.Encoder, only: [:id, :name, :slug, :disabled_page_types, :inserted_at]}
  schema "contexts" do
    field :name, :string
    field :slug, :string
    field :disabled_page_types, {:array, :string}, default: []

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "Changeset for creating a context"
  def changeset(context, attrs) do
    context
    |> cast(attrs, [:name, :slug])
    |> validate_required([:name, :slug])
    |> validate_length(:name, max: 100)
    |> validate_length(:slug, max: 100)
    |> unique_constraint(:name)
    |> unique_constraint(:slug)
  end

  @doc "Changeset for updating settings like disabled page types"
  def settings_changeset(context, attrs) do
    context
    |> cast(attrs, [:disabled_page_types])
    |> validate_subset(:disabled_page_types, Dran.Brain.Page.all_types())
  end
end
