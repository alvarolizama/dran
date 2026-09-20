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

  @doc """
  True when the instance has NO accounts yet: the account about to be created
  is the one that CLAIMS it, and is therefore its owner (`is_owner: true`).

  This is the ONE criterion behind "the first account is the admin", and every
  door into a fresh instance has to honour it:

    * `/setup` (`SessionController.setup/2`) — it only runs while this is true,
      and hard-codes the owner flag.
    * Google open-signup (`OAuthController.handle_google_user/2`) — it can fire
      BEFORE anybody ran /setup. `SetupLive` turns itself off as soon as ANY
      user exists, so without this rule the instance would be left with users
      and no owner: nobody able to reach `/admin`, ever.

  Callers use it to decide the flag, they do not assume it:
  `Accounts.create_user(%{…, is_owner: Accounts.claims_instance?()})`.
  """
  def claims_instance?, do: not any_users?()

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

  @doc """
  Creates an account WITHOUT a password.

  This is the identity-only path: Google auto-signup (`DranWeb.OAuthController`)
  creates the row and the person gets in with Google
  (`find_or_link_from_google/1` links by email).

  It is NOT how an admin gives an account to somebody. A row with no
  `password_hash` and no `google_id` has no way in — `authenticate_user/2`
  answers `{:error, :unauthorized}` for it, always — so the account is dead
  weight and an invitation to a workspace pointing at it leads nowhere. For a
  person who has to sign in, use `create_user_with_password/1` (what the
  /admin/users UI does).
  """
  def create_user(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> insert_user(attrs)
  end

  @doc """
  Creates an account WITH a password: the person signs in with email + password
  at /login as soon as this returns.

  The password is required by validation (see `User.registration_changeset/2`:
  email format, 8 characters minimum, bcrypt hash), so a call without one comes
  back as a changeset error instead of an account nobody can enter.
  """
  def create_user_with_password(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> insert_user(attrs)
  end

  # One insert path for both creations: the identity actor and the api_token
  # happen the same way whichever changeset — password or not — built the row,
  # so the two cannot drift apart.
  #
  # The `put_change/3` calls are NOT redundant: `User.changeset/2` casts neither
  # `:actor_id` nor `:password`, so putting them in the attrs is dropped in
  # silence. That is exactly what happened to the actor link: the row in `actors`
  # was created and the users.actor_id that resolves it was thrown away.
  defp insert_user(changeset, attrs) do
    changeset
    |> Ecto.Changeset.put_change(:actor_id, resolve_or_create_user_actor(email_from(attrs)))
    |> Ecto.Changeset.put_change(:api_token, User.generate_api_token())
    |> Repo.insert()
  end

  # Attrs arrive with atom keys (release setup, OAuth, tests) or with string
  # keys (a form's params, exactly as the client sent them — see the comment in
  # AdminUsersLive.handle_event/3 about why that matters).
  defp email_from(attrs), do: Map.get(attrs, :email) || Map.get(attrs, "email")

  def authenticate_user(email, password) when is_binary(email) and is_binary(password) do
    case get_user_by_email(email) do
      %User{password_hash: hash} = user when is_binary(hash) ->
        if Bcrypt.verify_pass(password, hash),
          do: {:ok, %{user | workspaces: []}},
          else: {:error, :unauthorized}

      _ ->
        # Constant-time for unknown emails — burn a dummy verification so
        # response timing does not reveal which emails exist.
        Bcrypt.no_user_verify()
        {:error, :unauthorized}
    end
  end

  def update_user(%User{} = user, attrs) do
    user
    |> User.changeset(attrs)
    |> Repo.update()
  end

  @doc "Update the user's display name (and optionally avatar_url)."
  def update_profile(%User{} = user, attrs) do
    user
    |> User.profile_changeset(attrs)
    |> Repo.update()
  end

  @doc "Change the user's password. Verifies current_password when one exists."
  def update_password(%User{} = user, attrs) do
    user
    |> User.update_password_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Update an account from the instance-owner surface (/admin/users): email, name
  and an optional password RESET, with no `current_password` check — see
  `User.admin_changeset/2` for why that is the point, not an oversight.

  Deliberately narrower than `update_user/2`: only the fields that surface edits
  are castable. The instance-level flag (`is_owner`) keeps going through its own
  function, and the whole thing is unreachable outside the `:admin` scope.
  """
  def update_user_as_admin(%User{} = user, attrs) do
    user
    |> User.admin_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Change the user's UI language (`"en"` | `"es"`).

  English is the app default; a `nil`/blank value falls back to it instead of
  erroring, so a malformed submit never leaves the account without a locale.
  """
  def update_locale(%User{} = user, locale) do
    locale =
      case DranWeb.Gettext.normalize_locale(locale) do
        nil -> DranWeb.Gettext.app_default_locale()
        normalized -> normalized
      end

    user
    |> User.locale_changeset(%{locale: locale})
    |> Repo.update()
  end

  @doc "Unlink the Google account: clears google_id and avatar_url."
  def unlink_google(%User{} = user) do
    user
    |> User.profile_changeset(%{google_id: nil, avatar_url: nil})
    |> Repo.update()
  end

  @doc "Link a Google account to an existing user (sets google_id + avatar)."
  def link_google(%User{} = user, %{google_id: google_id} = attrs) do
    user
    |> User.profile_changeset(%{
      google_id: google_id,
      avatar_url: attrs[:avatar_url],
      name: attrs[:name]
    })
    |> Repo.update()
  end

  @doc "True when the user has a Google account linked (google_id is set)."
  def google_linked?(%User{google_id: gid}) when is_binary(gid), do: true
  def google_linked?(_), do: false

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

  @doc """
  Add `user` to `workspace` with `role` (default `"viewer"`).
  """
  def add_user_to_workspace(%User{} = user, %Workspace{} = context, role \\ "viewer") do
    %UserWorkspace{}
    |> UserWorkspace.changeset(%{user_id: user.id, workspace_id: context.id, role: role})
    |> Repo.insert()
  end

  @doc """
  Add an EXISTING account to a workspace, looked up by email — this is what the
  UI calls "invite". Dran has no invitation emails: the person must already have
  an account on this instance.

  The lookup is case-insensitive (people retype their own address in any case),
  the stored email is untouched.

  Returns `{:ok, %UserWorkspace{}}`, `{:error, :user_not_found}` (no such
  account), `{:error, :already_member}`, or `{:error, changeset}`.
  """
  def add_member_by_email(%Workspace{} = workspace, email, role \\ "viewer")
      when is_binary(email) do
    case find_user_by_email_ci(String.trim(email)) do
      nil ->
        {:error, :user_not_found}

      %User{} = user ->
        if user_in_workspace?(user, workspace) do
          {:error, :already_member}
        else
          add_user_to_workspace(user, workspace, role)
        end
    end
  end

  defp find_user_by_email_ci(""), do: nil

  defp find_user_by_email_ci(email) do
    Repo.one(
      from u in User,
        where: fragment("lower(?) = lower(?)", u.email, ^email),
        limit: 1
    )
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
  The workspace a session should open for `%User{}` — the ONE place that
  decides where a user lands (login, cookie restoration, LiveView mounts,
  impersonation).

  W6 (contract-instance-visibility-20260919): there is nothing to resolve any
  more. The instance IS the container, so every account — owner, admin, editor,
  viewer, or an unknown/nil user — lands on the instance's slug. What is left of
  the old landing matrix is the fail-open fallback: the app always had a slug to
  answer with, and it still does.
  """
  def session_workspace_slug(%User{} = _user), do: Dran.Auth.default_workspace_slug()
  def session_workspace_slug(_), do: Dran.Auth.default_workspace_slug()

  # ── Owner / Role-based access ──

  def owner_user do
    Repo.get_by(User, is_owner: true) |> Repo.preload(:workspaces)
  end

  @doc """
  Update a user's role in a workspace.
  Validates the role against the allowed set and persists via UserWorkspace
  changeset.
  """
  def update_member_role(%User{} = user, %Workspace{} = workspace, role) do
    case Repo.get_by(UserWorkspace, user_id: user.id, workspace_id: workspace.id) do
      nil ->
        {:error, :not_a_member}

      %UserWorkspace{} = uw ->
        uw
        |> UserWorkspace.changeset(%{role: role})
        |> Repo.update()
    end
  end

  def is_owner?(%User{is_owner: true}), do: true
  def is_owner?(_), do: false

  @doc """
  Update the user's CONTENT preference inside a workspace
  (`content_scope`: "all" | "own").

  This is a per-user preference (D5): it narrows what the user — and the
  agents that inherit their ownership — read from the workspace. It never
  changes what they may WRITE (roles keep that).
  """
  def update_content_scope(%User{} = user, %Workspace{} = workspace, content_scope) do
    case Repo.get_by(UserWorkspace, user_id: user.id, workspace_id: workspace.id) do
      nil ->
        {:error, :not_a_member}

      %UserWorkspace{} = uw ->
        uw
        |> UserWorkspace.changeset(%{content_scope: content_scope})
        |> Repo.update()
    end
  end

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
    # W5 (single-workspace): a key reads/writes as its owner — the old
    # creator-membership gate on the requested workspaces stopped meaning
    # anything when the instance became the only workspace.
    with :ok <- validate_key_creator(attrs[:created_by_user_id]) do
      token = ApiKey.generate_token()

      # W3 (M6): creating a key NO LONGER creates/links an actor. The key is
      # its own agent identity (its `name`) and the only ownership link is
      # `created_by_user_id` — which is what `Auth.resolve_owner_user_id/1`
      # reads for attribution. `actor_id` stays NULL on new rows until the
      # M3 drop.
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
    end
  end

  defp validate_key_creator(user_id) do
    if is_nil(user_id) or Repo.get(User, user_id) != nil, do: :ok, else: {:error, :user_not_found}
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
  Replace the full workspace/access matrix of an API key transactionally:
  deletes every `api_key_workspaces` row and re-inserts the given list of
  `{workspace_id, access_level}` tuples. The key's token is preserved.

  `creator` is the user performing the change — membership of every
  requested workspace is validated against them (owners may use any).
  """
  def replace_api_key_workspaces(%ApiKey{} = key, workspace_ids, _creator \\ nil) do
    # W5: no membership matrix to validate — the key acts as its owner.
    Ecto.Multi.new()
    |> Ecto.Multi.delete_all(
      :drop_old,
      from(akw in ApiKeyWorkspace, where: akw.api_key_id == ^key.id)
    )
    |> Ecto.Multi.insert_all(
      :insert_new,
      ApiKeyWorkspace,
      Enum.map(workspace_ids, fn {wid, level} ->
        %{
          api_key_id: key.id,
          workspace_id: wid,
          access_level: level,
          inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
        }
      end),
      on_conflict: :nothing
    )
    |> Repo.transaction()
    |> case do
      {:ok, _} -> {:ok, reload_api_key(key)}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

  defp reload_api_key(%ApiKey{} = key) do
    Repo.preload(key, [:created_by_user, api_key_workspaces: :workspace])
  end

  @doc """
  Validate an API key token. Returns `{:ok, %ApiKey{}}` (with workspaces
  preloaded) only when the key exists AND is not revoked.
  """
  def valid_api_key?(token) when is_binary(token) do
    case Repo.get_by(ApiKey, token_hash: ApiKey.hash_token(token)) do
      %ApiKey{} = key ->
        if ApiKey.active?(key) do
          {:ok, Repo.preload(key, api_key_workspaces: :workspace, created_by_user: [])}
        else
          :error
        end

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

  # ── Actor linkage ──

  # Resolve (or lazily create) the kind=user actor for an email, used when
  # a user row is created. Never nil for a valid email — the actors table
  # is the instance-wide identity registry.
  defp resolve_or_create_user_actor(email) when is_binary(email) and email != "" do
    case Dran.Actors.get_actor_by_name(email) do
      nil ->
        case Dran.Actors.create_actor(%{name: email, kind: "user"}) do
          {:ok, actor} -> actor.id
          {:error, _} -> Dran.Actors.get_actor_by_name(email) |> actor_id()
        end

      %Dran.Actors.Actor{id: id} ->
        id
    end
  end

  defp resolve_or_create_user_actor(_), do: nil

  defp actor_id(%Dran.Actors.Actor{id: id}), do: id
  defp actor_id(_), do: nil
end
