defmodule Dran.PageVersion do
  @moduledoc """
  Snapshot of a page's body at a specific version. Append-only —
  created every time a page's body changes.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, read_after_writes: true}
  @foreign_key_type :binary_id

  @derive {Jason.Encoder,
           only: [:id, :page_id, :body, :body_hash, :version, :changed_by, :inserted_at]}
  schema "page_versions" do
    field :body, :string
    field :body_hash, :string
    field :version, :integer
    field :changed_by, :string

    belongs_to :page, Dran.Page

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "Changeset for creating a page version snapshot"
  def changeset(page_version, attrs) do
    page_version
    |> cast(attrs, [:page_id, :body, :body_hash, :version, :changed_by])
    |> validate_required([:page_id, :body, :version])
  end
end
