defmodule Dran.Brain.Log do
  @moduledoc """
  Append-only audit log. Records every meaningful action in the brain:
  page.create, page.update, page.delete, relation.add, etc.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, read_after_writes: true}
  @foreign_key_type :binary_id

  @derive {Jason.Encoder, only: [:id, :workspace_id, :action, :subject, :details, :inserted_at]}
  schema "brain_log" do
    field :action, :string
    field :subject, :string
    field :details, :map, default: %{}

    belongs_to :workspace, Dran.Brain.Workspace

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "Changeset for creating a log entry"
  def changeset(log, attrs) do
    log
    |> cast(attrs, [:workspace_id, :action, :subject, :details])
    |> validate_required([:action])
  end
end
