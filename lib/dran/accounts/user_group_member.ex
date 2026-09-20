defmodule Dran.Accounts.UserGroupMember do
  @moduledoc """
  Membership row: a user belongs to a group (W2). Composite uniqueness is
  enforced by the `(user_group_id, user_id)` unique index.
  """

  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :id

  schema "user_group_members" do
    belongs_to :user_group, Dran.Accounts.UserGroup
    belongs_to :user, Dran.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(member, attrs) do
    import Ecto.Changeset

    member
    |> cast(attrs, [:user_group_id, :user_id])
    |> validate_required([:user_group_id, :user_id])
    |> unique_constraint([:user_group_id, :user_id])
  end
end
