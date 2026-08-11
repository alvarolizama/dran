defmodule Dran.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :email, :string
    field :name, :string
    field :google_id, :string
    field :avatar_url, :string
    field :is_admin, :boolean, default: false
    field :is_editor, :boolean, default: false
    field :api_token, :string
    field :password_hash, :string
    field :default_context_slug, :string

    # Virtual — consumed by changeset, never persisted
    field :password, :string, virtual: true

    has_many :user_contexts, Dran.Accounts.UserContext
    has_many :contexts, through: [:user_contexts, :context]

    timestamps()
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [
      :email,
      :name,
      :google_id,
      :avatar_url,
      :is_admin,
      :is_editor,
      :api_token,
      :default_context_slug
    ])
    |> validate_required([:email])
    |> unique_constraint(:email)
    |> unique_constraint(:google_id)
    |> unique_constraint(:api_token)
  end

  @doc "Changeset for password-based registration. Requires email + password."
  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :name, :password])
    |> validate_required([:email, :password])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/)
    |> validate_length(:password, min: 8)
    |> unique_constraint(:email)
    |> put_password_hash()
  end

  defp put_password_hash(%Ecto.Changeset{valid?: true, changes: %{password: pass}} = changeset) do
    put_change(changeset, :password_hash, Bcrypt.hash_pwd_salt(pass))
  end

  defp put_password_hash(changeset), do: changeset

  def generate_api_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end
end
