defmodule Dran.Accounts.UserWorkspace do
  use Ecto.Schema
  import Ecto.Changeset

  schema "user_workspaces" do
    belongs_to :user, Dran.Accounts.User
    field :workspace_id, :binary_id
    belongs_to :workspace, Dran.Workspace, define_field: false
    field :role, :string, default: "viewer"
    # Personal content preference inside this workspace: "all" (see the whole
    # workspace) | "own" (only mine, including my agents' content). Agents
    # inherit the preference of their owner. See Dran.ContentVisibility.
    field :content_scope, :string, default: "all"

    timestamps()
  end

  @valid_roles ~w(owner admin editor viewer)
  @valid_content_scopes ~w(all own)

  def changeset(user_workspace, attrs) do
    user_workspace
    |> cast(attrs, [:user_id, :workspace_id, :role, :content_scope])
    |> validate_required([:user_id, :workspace_id])
    |> validate_inclusion(:role, @valid_roles)
    |> validate_inclusion(:content_scope, @valid_content_scopes)
    |> unique_constraint([:user_id, :workspace_id])
  end

  @doc "Valid content scopes."
  def content_scopes, do: @valid_content_scopes
end
