defmodule Dran.Accounts.UserContext do
  use Ecto.Schema
  import Ecto.Changeset

  schema "user_contexts" do
    belongs_to :user, Dran.Accounts.User
    belongs_to :context, Dran.Brain.Context

    timestamps()
  end

  def changeset(user_context, attrs) do
    user_context
    |> cast(attrs, [:user_id, :context_id])
    |> validate_required([:user_id, :context_id])
    |> unique_constraint([:user_id, :context_id])
  end
end
