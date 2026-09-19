defmodule Dran.Accounts do
  @moduledoc """
  Multi-user accounts context for Dran.

  Handles user management, authentication, and context membership.
  Each user has ONE api_token that grants access to ALL their assigned contexts.
  """

  import Ecto.Query
  require Logger
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
    attrs = Map.put(attrs, :actor_id, resolve_or_create_user_actor(attrs[:email]))

    %User{}
    |> User.changeset(attrs)
    |> Ecto.Changeset.put_change(:api_token, User.generate_api_token())
    |> Repo.insert()
    |> with_personal_workspace()
  end

  def create_user_with_password(%{email: _email, password: _pass} = attrs) do
    attrs = Map.put(attrs, :actor_id, resolve_or_create_user_actor(attrs[:email]))

    %User{}
    |> User.registration_changeset(attrs)
    |> Ecto.Changeset.put_change(:api_token, User.generate_api_token())
    |> Repo.insert()
    |> with_personal_workspace()
  end

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

  # ── Personal workspaces ──

  @doc """
  The user's personal workspace struct, or `nil` when they have none (or the
  pointer is stale).

  Read by the landing resolution (`session_workspace_slug/1`) and the admin
  surfaces. One PK lookup — never preloaded on `get_user_by_email/1`, which
  runs on every request.
  """
  def personal_workspace(%User{personal_workspace_id: id}) when is_binary(id),
    do: Repo.get(Workspace, id)

  def personal_workspace(_user), do: nil

  @doc """
  Idempotently ensure `user` has a personal workspace, creating it when missing.

  The personal workspace is PRIVATE (it is the user's own silo — nobody else
  sees it in their workspace list) and is linked back to the user two ways: the
  `users.personal_workspace_id` pointer (survives slug renames) and an `owner`
  membership (so every existing access check keeps working).

  `users.default_workspace_slug` is seeded with its slug ONLY when still blank —
  an explicit choice of landing workspace is never clobbered.

  Returns `{:ok, %Dran.Workspace{}}` or `{:error, changeset}`. Callers creating
  accounts degrade gracefully (see `with_personal_workspace/1`) and the release
  backfill re-runs it for everyone.
  """
  def ensure_personal_workspace(%User{} = user) do
    case do_ensure_personal_workspace(user) do
      {:ok, workspace, _user} -> {:ok, workspace}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Give every user that lacks one a personal workspace. Idempotent and safe to
  run on every deploy (release setup).

  Returns `{created, failed}` counts.
  """
  def backfill_personal_workspaces do
    User
    |> where([u], is_nil(u.personal_workspace_id))
    |> Repo.all()
    |> Enum.reduce({0, 0}, fn user, {created, failed} ->
      case ensure_personal_workspace(user) do
        {:ok, _workspace} -> {created + 1, failed}
        {:error, _reason} -> {created, failed + 1}
      end
    end)
  end

  # Returns `{:ok, workspace, user}` — the user being the row AS UPDATED, so the
  # caller can put it straight on the socket/return value without a re-fetch.
  # (Re-fetching with `get_user/1` would preload `:workspaces`/`:user_workspaces`
  # and `Repo.preload/2` never reloads an already-loaded association, so a later
  # `list_user_workspaces(user)` on that struct would report stale memberships.)
  #
  # The account row is locked FOR UPDATE and re-read INSIDE the transaction. That
  # is what turns "one personal workspace per account" into a guarantee instead
  # of a hope: without it, two concurrent calls — a signup racing the release
  # backfill, a double submit, two devices — both read
  # `personal_workspace_id = nil`, both create a workspace, and the loser's row
  # stays behind as an orphan the user still sees in their list. With the lock
  # the loser waits, re-reads, finds the winner's id and creates nothing.
  defp do_ensure_personal_workspace(%User{id: user_id}) do
    outcome =
      Repo.transaction(fn ->
        case Repo.one(from u in User, where: u.id == ^user_id, lock: "FOR UPDATE") do
          nil ->
            Repo.rollback(:user_not_found)

          user ->
            case user.personal_workspace_id && Repo.get(Workspace, user.personal_workspace_id) do
              %Workspace{} = workspace ->
                {:ok, workspace, user}

              nil ->
                case create_personal_workspace(user) do
                  {:ok, workspace, updated_user} -> {:ok, workspace, updated_user}
                  {:error, reason} -> Repo.rollback(reason)
                end
            end
        end
      end)

    case outcome do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_personal_workspace(%User{} = user) do
    # The display name is NOT uniquified: `workspaces.name` stopped being unique
    # once every account got a personal workspace, because two people called
    # "Alice" are two people called "Alice". The slug — the URL identity — is
    # derived from it by create_workspace/2, which suffixes it on collision, so
    # the second "Alice" gets /alice-3f9a2b.
    #
    # Private on purpose: a personal workspace is never the instance default and
    # never shows up in another user's workspace list.
    attrs = %{"name" => personal_workspace_name(user), "visibility" => "private"}

    case Dran.Knowledge.create_workspace(attrs, owner_user_id: user.id) do
      {:ok, %Workspace{} = workspace} ->
        case Repo.update(
               Ecto.Changeset.change(user,
                 personal_workspace_id: workspace.id,
                 default_workspace_slug: seed_default_slug(user, workspace.slug)
               )
             ) do
          {:ok, updated_user} -> {:ok, workspace, updated_user}
          {:error, changeset} -> {:error, changeset}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Seed the landing workspace only when nothing was chosen: a default the user
  # (or an admin) set on purpose always wins.
  defp seed_default_slug(%User{default_workspace_slug: slug}, _fallback)
       when is_binary(slug) and slug != "",
       do: slug

  defp seed_default_slug(_user, fallback), do: fallback

  defp personal_workspace_name(%User{name: name}) when is_binary(name) and name != "",
    do: name

  defp personal_workspace_name(%User{email: email}) when is_binary(email) do
    email |> String.split("@") |> List.first() |> String.capitalize()
  end

  defp personal_workspace_name(_user), do: "Personal"

  # ── Creating additional workspaces ──

  @doc """
  True when `user` may create additional workspaces: the instance owner always,
  or anyone explicitly granted `can_create_workspaces`.
  """
  def can_create_workspaces?(%User{} = user), do: User.can_create_workspaces?(user)
  def can_create_workspaces?(_user), do: false

  @doc """
  Create a workspace FOR `user`: they become its `owner` member in the same
  transaction as the workspace row.

  Two refusals, both enforced here and not only in the UI:

    * `{:error, :forbidden}` — the user has no `can_create_workspaces`
      permission. The personal workspace is exempt from it: that one is created
      by `ensure_personal_workspace/1`, never through here.
    * `{:error, :name_taken}` — they ALREADY have a workspace with that name in
      their own list. Names are not unique in the database (two people may both
      have a "Personal"), so the check is scoped to what this user can reach:
      refusing because of a workspace they cannot even open would leak its
      existence and help nobody. Inside their own list the repetition is a
      mistake worth catching — the alternative is silently handing them
      /trabajo-3f9a2b for a URL they never chose.
  """
  def create_workspace_for(%User{} = user, attrs) do
    cond do
      not can_create_workspaces?(user) -> {:error, :forbidden}
      name_taken_for?(user, attrs) -> {:error, :name_taken}
      true -> Dran.Knowledge.create_workspace(attrs, owner_user_id: user.id)
    end
  end

  # Case-insensitive and trimmed: to the person typing it, "Trabajo" and
  # " trabajo " are the same workspace — and they slugify to the same URL.
  defp name_taken_for?(%User{} = user, attrs) do
    case attrs_name(attrs) do
      nil ->
        false

      name ->
        wanted = normalize_name(name)
        Enum.any?(accessible_workspaces(user), &(normalize_name(&1.name) == wanted))
    end
  end

  defp attrs_name(attrs) do
    case Map.get(attrs, "name") || Map.get(attrs, :name) do
      name when is_binary(name) and name != "" -> name
      _ -> nil
    end
  end

  defp normalize_name(name) when is_binary(name), do: name |> String.trim() |> String.downcase()
  defp normalize_name(_name), do: ""

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
  Returns every workspace the user can reach: their MEMBERSHIPS only — the
  workspaces they were added to, plus their own personal one, which leads the
  list.

  Every workspace is private (`Dran.Workspace.changeset/2`), so there is nothing
  to discover: being able to open a workspace means somebody put you in it.

  Note the asymmetry with `DranWeb.Router.require_workspace_access/2` — the
  INSTANCE OWNER reaches every workspace of the instance, and that is where "the
  owner sees all" lives. This list carries only the owner's own memberships,
  which is exactly what the landing resolution and the org/propios split depend
  on.

  `nil` (no user row) yields `[]` — fail-closed, a session user with no DB row
  has no accessible workspaces.
  """
  def accessible_workspaces(%User{} = user) do
    user
    |> list_user_workspaces()
    |> order_personal_first(user.personal_workspace_id)
  end

  def accessible_workspaces(_), do: []

  # The personal workspace leads the list (and therefore the switcher): it is
  # where the user lands by default, so it should be the first thing they see.
  defp order_personal_first(workspaces, nil), do: workspaces

  defp order_personal_first(workspaces, personal_id) do
    {personal, rest} = Enum.split_with(workspaces, &(&1.id == personal_id))
    personal ++ rest
  end

  @doc """
  The workspace a session should open for `%User{}` — the ONE place that
  decides where a user lands (login, cookie restoration, LiveView mounts,
  impersonation).

  The landing workspace is the user's PERSONAL workspace: every account is
  created with one and `ensure_personal_workspace/1` seeds
  `default_workspace_slug` with it, so in the normal case the first rule below
  is what resolves. `default_workspace_slug` only ever differs from the
  personal slug when the user (from account settings) or an admin (from
  /admin/users) changes it on purpose — an explicit choice always wins.

  In order:

    1. the user's own `default_workspace_slug`, while they still have access,
    2. their personal workspace's slug, while the workspace still exists,
    3. the instance default, when they have access,
    4. the ONLY workspace they can access — no reason to drop them on an
       empty page because the flagged default is someone else's workspace,
    5. the instance default (fail-open to the same slug the app has always
       used; the caller decides how to render a missing workspace).

  For the instance owner rules 3-5 collapse into the instance default: the
  owner reaches every workspace (see `require_workspace_access/2`), so
  memberships never narrow their landing workspace.

  A nil / unknown user resolves to the instance default.
  """
  def session_workspace_slug(%User{is_owner: true} = user) do
    user_default_workspace(user) ||
      personal_workspace_slug(user) ||
      Dran.Auth.default_workspace_slug()
  end

  def session_workspace_slug(%User{} = user) do
    accessible = accessible_workspaces(user)
    slugs = Enum.map(accessible, & &1.slug)
    instance = Dran.Auth.default_workspace_slug()
    personal = personal_workspace_slug(user)

    cond do
      user.default_workspace_slug in slugs -> user.default_workspace_slug
      personal && personal in slugs -> personal
      instance in slugs -> instance
      true -> only_accessible_slug(accessible, instance)
    end
  end

  def session_workspace_slug(_), do: Dran.Auth.default_workspace_slug()

  # The personal workspace's slug, while the row still exists. One PK lookup:
  # `session_workspace_slug/1` runs on login / cookie restoration / a mount
  # without a session slug, never per request.
  defp personal_workspace_slug(%User{personal_workspace_id: id}) when is_binary(id) do
    case Repo.get(Workspace, id) do
      %Workspace{slug: slug} -> slug
      nil -> nil
    end
  end

  defp personal_workspace_slug(_user), do: nil

  # The user's configured default, only while the workspace still exists.
  defp user_default_workspace(%User{default_workspace_slug: slug})
       when is_binary(slug) and slug != "" do
    if Dran.Knowledge.get_workspace_by_slug(slug), do: slug, else: nil
  end

  defp user_default_workspace(_), do: nil

  defp only_accessible_slug([%{slug: slug}], _instance), do: slug
  defp only_accessible_slug(_accessible, instance), do: instance

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
    # Workspace membership validation
    case validate_workspace_access(attrs[:created_by_user_id], workspace_ids) do
      :ok ->
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

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Keys without a creator user (system/test-created): the workspace list
  # cannot be membership-validated, so require every referenced workspace to
  # exist — no blanket allow of arbitrary ids.
  defp validate_workspace_access(nil, workspace_ids) do
    {ids, _levels} = Enum.unzip(workspace_ids)

    existing =
      from(w in Workspace, where: w.id in ^ids, select: w.id)
      |> Repo.all()
      |> MapSet.new()

    missing = Enum.reject(ids, &MapSet.member?(existing, &1))

    if missing == [],
      do: :ok,
      else: {:error, :workspace_not_found}
  end

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
  def replace_api_key_workspaces(%ApiKey{} = key, workspace_ids, creator \\ nil) do
    case validate_workspace_access(creator && creator.id, workspace_ids) do
      {:error, reason} ->
        {:error, reason}

      :ok ->
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

  # ── Actor linkage ──

  # Every account gets its personal workspace at creation time. A failure here
  # must NOT abort account creation — the account is valid and the idempotent
  # `backfill_personal_workspaces/0` (run by release setup) will create it on
  # the next boot. Loud in the logs, never silent.
  defp with_personal_workspace({:ok, %User{} = user}) do
    case do_ensure_personal_workspace(user) do
      {:ok, _workspace, updated_user} ->
        {:ok, updated_user}

      {:error, reason} ->
        Logger.warning(
          "[accounts] personal workspace for #{user.email} could not be created " <>
            "(#{inspect(reason)}); run Dran.Release.setup (backfill) to retry"
        )

        {:ok, user}
    end
  end

  defp with_personal_workspace(other), do: other

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
