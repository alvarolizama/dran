defmodule Dran.Accounts.UserContext do
  use Ecto.Schema
  import Ecto.Changeset

  schema "user_contexts" do
    belongs_to :user, Dran.Accounts.User
    field :context_id, :binary_id
    belongs_to :context, Dran.Brain.Context, define_field: false

    timestamps()
  end

  def changeset(user_context, attrs) do
    user_context
    |> cast(attrs, [:user_id, :context_id])
    |> validate_required([:user_id, :context_id])
    |> unique_constraint([:user_id, :context_id])
  end
end
