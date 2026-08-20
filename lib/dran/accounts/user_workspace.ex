defmodule Dran.Accounts.UserWorkspace do
  use Ecto.Schema
  import Ecto.Changeset

  schema "user_workspaces" do
    belongs_to :user, Dran.Accounts.User
    field :workspace_id, :binary_id
    belongs_to :workspace, Dran.Brain.Workspace, define_field: false
    field :role, :string, default: "viewer"

    timestamps()
  end

  @valid_roles ~w(owner admin editor viewer)

  def changeset(user_workspace, attrs) do
    user_workspace
    |> cast(attrs, [:user_id, :workspace_id, :role])
    |> validate_required([:user_id, :workspace_id])
    |> validate_inclusion(:role, @valid_roles)
    |> unique_constraint([:user_id, :workspace_id])
  end
end
