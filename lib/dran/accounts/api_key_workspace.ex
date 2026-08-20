defmodule Dran.Accounts.ApiKeyWorkspace do
  @moduledoc """
  Schema for the `api_key_workspaces` join table.
  Links an API key to a workspace with a specific access level.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, read_after_writes: true}
  @foreign_key_type :binary_id

  schema "api_key_workspaces" do
    field :access_level, :string, default: "read"

    belongs_to :api_key, Dran.Accounts.ApiKey
    belongs_to :workspace, Dran.Brain.Workspace

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(api_key_workspace, attrs) do
    api_key_workspace
    |> cast(attrs, [:access_level, :api_key_id, :workspace_id])
    |> validate_required([:access_level, :api_key_id, :workspace_id])
    |> validate_inclusion(:access_level, ["read", "write"])
    |> foreign_key_constraint(:api_key_id)
    |> foreign_key_constraint(:workspace_id)
    |> unique_constraint([:api_key_id, :workspace_id])
  end
end
