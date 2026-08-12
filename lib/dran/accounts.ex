defmodule Dran.Accounts do
  @moduledoc """
  Multi-user accounts context for Dran.

  Handles user management, authentication, and context membership.
  Each user has ONE api_token that grants access to ALL their assigned contexts.
  """

  import Ecto.Query
  alias Dran.Repo
  alias Dran.Accounts.{User, UserContext}
  alias Dran.Brain.Context

  # ── User CRUD ──

  def list_users do
    Repo.all(User) |> Repo.preload(:contexts)
  end

  @doc "True when at least one user exists (setup already completed)."
  def any_users?, do: Repo.exists?(User)

  def get_user!(id), do: Repo.get!(User, id) |> Repo.preload(:contexts)
  def get_user(id), do: Repo.get(User, id) |> Repo.preload(:contexts)

  def get_user_by_email(email) do
    Repo.get_by(User, email: email) |> Repo.preload(:contexts)
  end

  def get_user_by_google_id(google_id) do
    Repo.get_by(User, google_id: google_id) |> Repo.preload(:contexts)
  end

  def get_user_by_api_token(token) when is_binary(token) do
    Repo.get_by(User, api_token: token) |> Repo.preload(:contexts)
  end

  def create_user(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Ecto.Changeset.put_change(:api_token, User.generate_api_token())
    |> Repo.insert()
  end

  def create_user_with_password(%{email: _email, password: _pass} = attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Ecto.Changeset.put_change(:api_token, User.generate_api_token())
    |> Repo.insert()
  end

  def authenticate_user(email, password) when is_binary(email) and is_binary(password) do
    case get_user_by_email(email) do
      %User{password_hash: hash} = user when is_binary(hash) ->
        if Bcrypt.verify_pass(password, hash),
          do: {:ok, %{user | contexts: []}},
          else: {:error, :unauthorized}

      _ ->
        {:error, :unauthorized}
    end
  end

  def update_user(%User{} = user, attrs) do
    user
    |> User.changeset(attrs)
    |> Repo.update()
  end

  def delete_user(%User{} = user), do: Repo.delete(user)

  # ── Google OAuth ──

  @doc """
  Finds a user for Google OAuth login without ever creating one.

  Looks up by `google_id` first, then falls back to `email` (linking the
  google_id onto an already-existing account). Unknown users are rejected
  with `{:error, :unauthorized}` — accounts can only be created by an admin
  via Settings (or the first-run `/setup` flow).
  """
  def find_or_link_from_google(%{email: email, google_id: google_id} = attrs) do
    case get_user_by_google_id(google_id) do
      %User{} = user ->
        {:ok, user}

      nil ->
        case get_user_by_email(email) do
          %User{} = user ->
            update_user(user, %{
              google_id: google_id,
              name: attrs[:name],
              avatar_url: attrs[:avatar_url]
            })

          nil ->
            {:error, :unauthorized}
        end
    end
  end

  # ── Context membership ──

  def add_user_to_context(%User{} = user, %Context{} = context) do
    %UserContext{}
    |> UserContext.changeset(%{user_id: user.id, context_id: context.id})
    |> Repo.insert()
  end

  def remove_user_from_context(%User{} = user, %Context{} = context) do
    UserContext
    |> where([uc], uc.user_id == ^user.id and uc.context_id == ^context.id)
    |> Repo.delete_all()
  end

  def user_in_context?(%User{} = user, %Context{} = context) do
    UserContext
    |> where([uc], uc.user_id == ^user.id and uc.context_id == ^context.id)
    |> Repo.exists?()
  end

  def list_user_contexts(%User{} = user) do
    user |> Repo.preload(:contexts) |> Map.get(:contexts)
  end

  # ── Admin ──

  def admin_user do
    Repo.get_by(User, is_admin: true) |> Repo.preload(:contexts)
  end

  def is_admin?(%User{is_admin: true}), do: true
  def is_admin?(_), do: false

  # ── API Token auth ──

  def valid_token?(token) when is_binary(token) do
    case get_user_by_api_token(token) do
      %User{} = user -> {:ok, user}
      nil -> :error
    end
  end

  @doc """
  Generates and persists a new API token for a user, invalidating the old one.
  Returns `{:ok, %User{}}` or `{:error, changeset}`.
  """
  def regenerate_api_token(%User{} = user) do
    user
    |> User.changeset(%{api_token: User.generate_api_token()})
    |> Repo.update()
  end

  # ── Context-scoped API keys ──

  alias Dran.Accounts.ApiKey

  @doc """
  List all API keys (active and revoked) with their context preloaded,
  newest first.
  """
  def list_api_keys do
    ApiKey
    |> order_by([k], desc: k.inserted_at)
    |> Repo.all()
    |> Repo.preload(:context)
  end

  @doc """
  Create a context-scoped API key.

  Returns `{:ok, %ApiKey{token: plaintext}}` — the plaintext token is only
  available in this return value and is never stored. Only its hash and an
  8-char display prefix are persisted.
  """
  def create_api_key(%{name: _name, context_id: _context_id} = attrs) do
    token = ApiKey.generate_token()

    %ApiKey{}
    |> ApiKey.changeset(%{
      name: attrs.name,
      context_id: attrs.context_id,
      write_access: Map.get(attrs, :write_access, false),
      token_hash: ApiKey.hash_token(token),
      token_prefix: ApiKey.prefix_of(token)
    })
    |> Repo.insert()
    |> case do
      {:ok, key} -> {:ok, %{key | token: token}}
      error -> error
    end
  end

  @doc """
  Update an API key's mutable fields (currently `write_access`).
  """
  def update_api_key(%ApiKey{} = key, attrs) do
    key
    |> ApiKey.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Validate an API key token. Returns `{:ok, %ApiKey{}}` (with context
  preloaded) only when the key exists AND is not revoked.
  """
  def valid_api_key?(token) when is_binary(token) do
    case Repo.get_by(ApiKey, token_hash: ApiKey.hash_token(token)) do
      %ApiKey{} = key ->
        if ApiKey.active?(key), do: {:ok, Repo.preload(key, :context)}, else: :error

      nil ->
        :error
    end
  end

  def valid_api_key?(_), do: :error

  @doc """
  Revoke an API key by setting `revoked_at`. The key stops working
  immediately but remains listed for audit.
  """
  def revoke_api_key(%ApiKey{} = key) do
    key
    |> Ecto.Changeset.change(revoked_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update()
  end

  @doc """
  Un-revoke an API key.
  """
  def restore_api_key(%ApiKey{} = key) do
    key
    |> Ecto.Changeset.change(revoked_at: nil)
    |> Repo.update()
  end

  @doc """
  Regenerate a key's token: new hash + prefix, clears revocation.
  The old token stops working immediately. Returns `{:ok, %ApiKey{token: ...}}`
  with the new plaintext token.
  """
  def regenerate_api_key(%ApiKey{} = key) do
    token = ApiKey.generate_token()

    key
    |> Ecto.Changeset.change(
      token_hash: ApiKey.hash_token(token),
      token_prefix: ApiKey.prefix_of(token),
      revoked_at: nil
    )
    |> Repo.update()
    |> case do
      {:ok, key} -> {:ok, %{key | token: token}}
      error -> error
    end
  end

  @doc """
  Permanently delete an API key row.
  """
  def delete_api_key(%ApiKey{} = key), do: Repo.delete(key)

  # ── Per-user default context ──

  @doc """
  Set a user's default context slug. Used as fallback when no context has
  been explicitly chosen in the session/cookie yet.
  """
  def set_default_context(%User{} = user, slug) when is_binary(slug) do
    user
    |> Ecto.Changeset.change(default_context_slug: slug)
    |> Repo.update()
  end
end
