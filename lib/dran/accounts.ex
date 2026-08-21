defmodule Dran.Accounts do
  @moduledoc """
  Multi-user accounts context for Dran.

  Handles user management, authentication, and context membership.
  Each user has ONE api_token that grants access to ALL their assigned contexts.
  """

  import Ecto.Query
  alias Dran.Repo
  alias Dran.Accounts.{User, UserWorkspace}
  alias Dran.Workspace

  # ── User CRUD ──

  def list_users do
    Repo.all(User) |> Repo.preload(:workspaces)
  end

  @doc "True when at least one user exists (setup already completed)."
  def any_users?, do: Repo.exists?(User)

  def get_user!(id), do: Repo.get!(User, id) |> Repo.preload(:workspaces)
  def get_user(id), do: Repo.get(User, id) |> Repo.preload(:workspaces)

  def get_user_by_email(email) do
    Repo.get_by(User, email: email) |> Repo.preload(:workspaces)
  end

  def get_user_by_google_id(google_id) do
    Repo.get_by(User, google_id: google_id) |> Repo.preload(:workspaces)
  end

  def get_user_by_api_token(token) when is_binary(token) do
    Repo.get_by(User, api_token: token) |> Repo.preload(:workspaces)
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
          do: {:ok, %{user | workspaces: []}},
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
  with `{:error, :unauthorized}` — this function never creates accounts;
  auto-registration happens in the OAuth controller only when the
  `wiki_google_open_signup` setting is enabled.
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

  def add_user_to_workspace(%User{} = user, %Workspace{} = context) do
    %UserWorkspace{}
    |> UserWorkspace.changeset(%{user_id: user.id, workspace_id: context.id})
    |> Repo.insert()
  end

  def remove_user_from_workspace(%User{} = user, %Workspace{} = context) do
    UserWorkspace
    |> where([uc], uc.user_id == ^user.id and uc.workspace_id == ^context.id)
    |> Repo.delete_all()
  end

  def user_in_workspace?(%User{} = user, %Workspace{} = context) do
    UserWorkspace
    |> where([uc], uc.user_id == ^user.id and uc.workspace_id == ^context.id)
    |> Repo.exists?()
  end

  def list_user_workspaces(%User{} = user) do
    user
    |> Repo.preload(user_workspaces: :workspace)
    |> Map.get(:user_workspaces)
    |> Enum.map(fn uw -> Map.put(uw.workspace, :role, uw.role) end)
  end

  @doc """
  Returns every workspace the user can access: their assigned (member)
  workspaces spliced together with all public workspaces of the instance.
  Owners see all workspaces. Public non-members see member + public workspaces,
  with public workspaces they are not a member of carrying `role: "viewer"`.

  `nil` (no user row) yields `[]` — fail-closed, a session user with no DB row
  has no accessible workspaces. The owner branch reuses `list_user_workspaces`
  (owner sees all), the member role merge mirrors that same pattern.
  """
  def accessible_workspaces(%User{is_owner: true} = user), do: list_user_workspaces(user)

  def accessible_workspaces(%User{id: user_id}) do
    # Member workspaces with their real role (same merge as list_user_workspaces).
    memberships =
      UserWorkspace
      |> where([uw], uw.user_id == ^user_id)
      |> order_by([uw], uw.inserted_at)
      |> Repo.all()
      |> Repo.preload(:workspace)
      |> Enum.map(fn uw -> Map.put(uw.workspace, :role, uw.role) end)

    member_ids = Enum.map(memberships, & &1.id)

    # Public workspaces the user is NOT a member of, defaulted to viewer role.
    public_others =
      Workspace
      |> where([ws], ws.visibility == "public")
      |> where([ws], ws.id not in ^member_ids)
      |> order_by([ws], ws.inserted_at)
      |> Repo.all()
      |> Enum.map(&Map.put(&1, :role, "viewer"))

    memberships ++ public_others
  end

  def accessible_workspaces(_), do: []

  # ── Owner / Role-based access ──

  def owner_user do
    Repo.get_by(User, is_owner: true) |> Repo.preload(:workspaces)
  end

  def is_owner?(%User{is_owner: true}), do: true
  def is_owner?(_), do: false

  @doc """
  Returns the user's role string for a given workspace.
  Falls back to "viewer" if no membership exists.
  """
  def user_role_in_workspace(%User{id: user_id}, %Workspace{id: workspace_id}) do
    case Repo.get_by(UserWorkspace, user_id: user_id, workspace_id: workspace_id) do
      %{role: role} -> role
      nil -> "viewer"
    end
  end

  @doc """
  True if the user can create API keys in the given workspace.
  Owners, admins, and editors can create keys.
  """
  def can_create_api_keys?(%User{} = user, %Workspace{} = workspace) do
    case user_role_in_workspace(user, workspace) do
      "owner" -> true
      "admin" -> true
      "editor" -> true
      _ -> false
    end
  end

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

  alias Dran.Accounts.{ApiKey, ApiKeyWorkspace}

  @doc """
  List all API keys (active and revoked) with associations preloaded,
  newest first.
  """
  def list_api_keys do
    ApiKey
    |> order_by([k], desc: k.inserted_at)
    |> Repo.all()
    |> Repo.preload([:created_by_user, api_key_workspaces: :workspace])
  end

  @doc """
  List API keys scoped to a specific user.

  Owners (`user.is_owner == true`) see all keys. Other users only see keys
  they created (`created_by_user_id == user.id`).
  """
  def list_api_keys(%User{is_owner: true}) do
    list_api_keys()
  end

  # No user in session (e.g. pre-auth mount): no keys.
  def list_api_keys(nil), do: []

  def list_api_keys(%User{id: user_id}) do
    ApiKey
    |> where([k], k.created_by_user_id == ^user_id)
    |> order_by([k], desc: k.inserted_at)
    |> Repo.all()
    |> Repo.preload([:created_by_user, api_key_workspaces: :workspace])
  end

  @doc """
  Create a context-scoped API key.

  Accepts:
    - `name`: Key name (required)
    - `created_by_user_id`: The user who created this key (optional)
    - `workspace_ids`: List of `{workspace_id, access_level}` tuples (required, can be empty)

  Returns `{:ok, %ApiKey{token: plaintext}}` — the plaintext token is only
  available in this return value and is never stored. Only its hash and an
  8-char display prefix are persisted.
  """
  # New multi-workspace signature: %{name:, workspace_ids: [{wid, level}]}
  def create_api_key(%{name: _name, workspace_ids: workspace_ids} = attrs) do
    do_create_api_key(attrs, workspace_ids)
  end

  # Single-workspace backward-compat: %{name:, workspace_id:, write_access?}
  # (tests and settings_live still use this format)
  def create_api_key(%{name: _name, workspace_id: wid} = attrs) do
    write_access = Map.get(attrs, :write_access, false)
    workspace_ids = [{wid, if(write_access, do: "write", else: "read")}]
    do_create_api_key(attrs, workspace_ids)
  end

  defp do_create_api_key(attrs, workspace_ids) do
    # Workspace membership validation
    case validate_workspace_access(attrs[:created_by_user_id], workspace_ids) do
      :ok ->
        token = ApiKey.generate_token()

        Ecto.Multi.new()
        |> Ecto.Multi.insert(
          :api_key,
          %ApiKey{}
          |> ApiKey.changeset(%{
            name: attrs.name,
            created_by_user_id: attrs[:created_by_user_id],
            token_hash: ApiKey.hash_token(token),
            token_prefix: ApiKey.prefix_of(token)
          })
        )
        |> Ecto.Multi.run(:workspace_entries, fn _repo, %{api_key: api_key} ->
          entries =
            Enum.map(workspace_ids, fn {wid, level} ->
              %ApiKeyWorkspace{}
              |> ApiKeyWorkspace.changeset(%{
                api_key_id: api_key.id,
                workspace_id: wid,
                access_level: level
              })
            end)

          {:ok, entries}
        end)
        |> Ecto.Multi.run(:insert_workspace_entries, fn _repo, %{workspace_entries: entries} ->
          Enum.each(entries, fn changeset ->
            Repo.insert!(changeset)
          end)

          {:ok, :done}
        end)
        |> Repo.transaction()
        |> case do
          {:ok, %{api_key: key}} -> {:ok, %{key | token: token}}
          {:error, :api_key, changeset, _} -> {:error, changeset}
          {:error, _step, reason, _} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_workspace_access(nil, _workspace_ids), do: :ok

  defp validate_workspace_access(user_id, workspace_ids) do
    user = Repo.get(User, user_id)

    cond do
      user == nil ->
        {:error, :user_not_found}

      is_owner?(user) ->
        :ok

      true ->
        allowed_workspaces =
          UserWorkspace
          |> where([uw], uw.user_id == ^user_id)
          |> select([uw], uw.workspace_id)
          |> Repo.all()
          |> MapSet.new()

        requested_workspaces =
          Enum.map(workspace_ids, fn {wid, _level} -> wid end)

        if Enum.all?(requested_workspaces, &MapSet.member?(allowed_workspaces, &1)) do
          :ok
        else
          {:error, :workspace_not_allowed}
        end
    end
  end

  @doc """
  Update an API key's mutable fields (currently `name`).
  """
  def update_api_key(%ApiKey{} = key, attrs) do
    # Backward compat: if write_access is passed, toggle the
    # access_level on the first api_key_workspace.
    case Map.get(attrs, :write_access) do
      nil ->
        :ok

      write? ->
        # Update the first (or only) api_key_workspace's access_level
        akw =
          Repo.one(
            from a in Dran.Accounts.ApiKeyWorkspace,
              where: a.api_key_id == ^key.id,
              limit: 1
          )

        if akw do
          level = if(write?, do: "write", else: "read")

          akw
          |> Dran.Accounts.ApiKeyWorkspace.changeset(%{access_level: level})
          |> Repo.update!()
        end
    end

    # Also support name updates
    if Map.get(attrs, :name) do
      key
      |> ApiKey.changeset(%{name: attrs.name})
      |> Repo.update()
    else
      {:ok, key}
    end
  end

  @doc """
  Update workspaces for an API key.

  Accepts a list of `{workspace_id, access_level}` tuples.
  Replaces all existing workspace associations.
  """
  def update_api_key_workspaces(%ApiKey{} = key, workspace_ids) do
    # Delete existing
    ApiKeyWorkspace
    |> where([w], w.api_key_id == ^key.id)
    |> Repo.delete_all()

    # Insert new
    entries =
      Enum.map(workspace_ids, fn {wid, level} ->
        %ApiKeyWorkspace{}
        |> ApiKeyWorkspace.changeset(%{
          api_key_id: key.id,
          workspace_id: wid,
          access_level: level
        })
        |> Repo.insert!()
      end)

    {:ok, entries}
  end

  @doc """
  Update the access level for a specific workspace in an API key.
  Returns `{:ok, updated_workspace}` or `{:error, reason}`.
  """
  def update_api_key_access(%ApiKey{id: key_id}, workspace_id, access_level)
      when access_level in ["read", "write"] do
    case Repo.get_by(ApiKeyWorkspace, api_key_id: key_id, workspace_id: workspace_id) do
      nil ->
        {:error, :workspace_not_found_for_key}

      akw ->
        akw
        |> ApiKeyWorkspace.changeset(%{access_level: access_level})
        |> Repo.update()
    end
  end

  def update_api_key_access(_, _, _), do: {:error, :invalid_access_level}

  @doc """
  Validate an API key token. Returns `{:ok, %ApiKey{}}` (with workspaces
  preloaded) only when the key exists AND is not revoked.
  """
  def valid_api_key?(token) when is_binary(token) do
    case Repo.get_by(ApiKey, token_hash: ApiKey.hash_token(token)) do
      %ApiKey{} = key ->
        if ApiKey.active?(key),
          do: {:ok, Repo.preload(key, api_key_workspaces: :workspace, created_by_user: [])},
          else: :error

      nil ->
        :error
    end
  end

  def valid_api_key?(_), do: :error

  @doc """
  Check if an API key has access (read or write) to a specific workspace.
  Returns the access level string or nil.
  """
  def api_key_access_level(%ApiKey{api_key_workspaces: workspaces}, workspace_id)
      when is_list(workspaces) do
    case Enum.find(workspaces, fn w -> w.workspace_id == workspace_id end) do
      %{access_level: level} -> level
      _ -> nil
    end
  end

  def api_key_access_level(_, _), do: nil

  @doc """
  Check if an API key has write access to a specific workspace.
  """
  def api_key_has_write_access?(%ApiKey{} = key, workspace_id) do
    api_key_access_level(key, workspace_id) == "write"
  end

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
    |> Ecto.Changeset.change(default_workspace_slug: slug)
    |> Repo.update()
  end
end
