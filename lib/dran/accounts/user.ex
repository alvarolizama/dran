defmodule Dran.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  use Gettext, backend: DranWeb.Gettext

  # Idiomas que la UI ofrece en Account settings. El inglés es el default de la
  # app (`DranWeb.Gettext.app_default_locale/0`); el español es el secundario.
  @locales ~w(en es)

  schema "users" do
    field :email, :string
    field :name, :string
    field :google_id, :string
    field :avatar_url, :string
    field :is_owner, :boolean, default: false
    field :api_token, :string
    field :password_hash, :string
    field :default_workspace_slug, :string

    # UI language: "en" (default) or "es". Read by DranWeb.Plugs.Locale and
    # DranWeb.Plugs.Auth.assign_to_socket/3 to pin Gettext per request.
    field :locale, :string, default: "en"

    # The user's global identity actor (kind: user). Backfilled 1:1 from
    # email; nullable until the actor row exists (see actors migration).
    field :actor_id, :binary_id

    # Virtual — consumed by changeset, never persisted
    field :password, :string, virtual: true
    field :current_password, :string, virtual: true

    has_many :user_workspaces, Dran.Accounts.UserWorkspace
    has_many :workspaces, through: [:user_workspaces, :workspace]
    belongs_to :actor, Dran.Actors.Actor, define_field: false, foreign_key: :actor_id

    timestamps()
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [
      :email,
      :name,
      :google_id,
      :avatar_url,
      :is_owner,
      :api_token,
      :default_workspace_slug
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

  @doc """
  Changeset for changing the password of an existing user.

  Requires `password` (new, min 8 chars) and `current_password` (verified
  against the stored hash when one exists). Users without a password_hash
  (Google-only accounts) skip the current-password check.
  """
  def update_password_changeset(user, attrs) do
    user
    |> cast(attrs, [:password, :current_password])
    |> validate_required([:password], message: gettext("Enter a new password"))
    |> validate_length(:password, min: 8)
    |> validate_current_password()
    |> put_password_hash()
  end

  defp validate_current_password(changeset) do
    current = get_field(changeset, :current_password)
    stored = get_field(changeset, :password_hash)

    cond do
      # Google-only account (no hash yet): allow setting a password directly.
      is_nil(stored) ->
        changeset

      # Must verify the current password when one exists.
      is_nil(current) ->
        add_error(changeset, :current_password, gettext("Enter your current password"))

      Bcrypt.verify_pass(current, stored) ->
        changeset

      true ->
        add_error(changeset, :current_password, gettext("The current password is incorrect"))
    end
  end

  @doc "Changeset for profile updates: name, avatar_url, google_id (unlink)."
  def profile_changeset(user, attrs) do
    user
    |> cast(attrs, [:name, :avatar_url, :google_id])
  end

  @doc """
  Changeset for the UI language preference.

  Only the two shipped locales are accepted; anything else is rejected so a
  stray value can never leave the app without translations.
  """
  def locale_changeset(user, attrs) do
    user
    |> cast(attrs, [:locale])
    |> validate_required([:locale])
    |> validate_inclusion(:locale, @locales)
  end

  @doc "Idiomas ofrecidos en la UI (inglés por defecto)."
  def locales, do: @locales

  defp put_password_hash(%Ecto.Changeset{valid?: true, changes: %{password: pass}} = changeset) do
    put_change(changeset, :password_hash, Bcrypt.hash_pwd_salt(pass))
  end

  defp put_password_hash(changeset), do: changeset

  def generate_api_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end
end
