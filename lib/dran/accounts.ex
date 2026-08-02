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

  def update_user(%User{} = user, attrs) do
    user
    |> User.changeset(attrs)
    |> Repo.update()
  end

  def delete_user(%User{} = user), do: Repo.delete(user)

  # ── Google OAuth ──

  def find_or_create_from_google(%{email: email, google_id: google_id} = attrs) do
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
            create_user(%{
              email: email,
              google_id: google_id,
              name: attrs[:name],
              avatar_url: attrs[:avatar_url]
            })
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
end
