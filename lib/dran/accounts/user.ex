defmodule Dran.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :email, :string
    field :name, :string
    field :google_id, :string
    field :avatar_url, :string
    field :is_admin, :boolean, default: false
    field :api_token, :string

    has_many :user_contexts, Dran.Accounts.UserContext
    has_many :contexts, through: [:user_contexts, :context]

    timestamps()
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :name, :google_id, :avatar_url, :is_admin, :api_token])
    |> validate_required([:email])
    |> unique_constraint(:email)
    |> unique_constraint(:google_id)
    |> unique_constraint(:api_token)
  end

  def generate_api_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end
end
