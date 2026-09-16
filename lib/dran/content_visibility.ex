defmodule Dran.ContentVisibility do
  @moduledoc """
  The single read-visibility policy for content (memories + knowledge pages).

  Read visibility is decided in exactly ONE place. `Memory`, `Knowledge`, the
  graph, REST, MCP and the LiveViews all funnel through `scope/3` and
  `filter/3` — there are no ad-hoc checks per controller or per template.

  ## The one vocabulary: the scope

  A scope is either:

    * `:all` — the reader sees every visible row of the workspace
    * `{:own, user_id | nil}` — the reader sees only rows whose
      `owner_user_id` matches. `{:own, nil}` means "only workspace content"
      (rows with a NULL owner), which is what an unattributable agent sees
      inside an isolated workspace.

  ## The policy

  Per workspace, two booleans decide the sharing policy of the instance:

    * `share_memory` — memories are shared across the workspace
    * `share_pages`  — pages are shared across the workspace

  Per user, `user_workspaces.content_scope` (`"all"` | `"own"`) is the
  personal preference: "todo el workspace" vs "solo míos". Agents inherit
  the preference of their owner (the user that owns the actor behind the
  API key), never a per-key setting.

  Combining both, for a non-privileged reader:

    | workspace policy | content_scope | scope           |
    |------------------|---------------|-----------------|
    | shared (true)    | "all"         | `:all`          |
    | shared (true)    | "own"         | `{:own, id}`    |
    | isolated (false) | any           | `{:own, id}`    |

  The owner/admin of the workspace and the instance owner always keep the
  full view (`:all`).

  ## Posture

  * `nil` identity → `:all`. This preserves the pre-existing read behaviour
    (the authorization layer already decides whether the request reaches the
    workspace at all) and keeps the legacy surfaces working.
  * An unknown identity shape → `:all`, same reason. Only shapes this module
    understands are narrowed.
  * A missing `share_*` field (workspace struct not loaded with the column)
    defaults to `true` = shared, the pre-feature behaviour.
  """

  import Ecto.Query, only: [from: 2]

  alias Dran.Accounts.UserWorkspace
  alias Dran.Repo

  @type kind :: :memory | :pages
  @type scope :: :all | {:own, integer() | nil}
  @type identity :: struct() | map() | nil

  @roles_full_view ~w(owner admin)
  @content_scopes ~w(all own)

  @doc """
  Resolve the read scope of `identity` inside `workspace` for `kind`
  (`:memory` | `:pages`).

  `workspace` may be a `%Dran.Workspace{}` or any map carrying
  `share_memory` / `share_pages`.
  """
  @spec scope(map() | struct() | nil, identity(), kind()) :: scope()
  def scope(_workspace, nil, _kind), do: :all

  # Instance owner / legacy admin identity shapes.
  def scope(_workspace, %{is_owner: true}, _kind), do: :all

  # Per-user token: workspace members. owner/admin keep the full view.
  def scope(workspace, %Dran.Accounts.User{id: user_id} = user, kind) do
    case Dran.Accounts.user_role_in_workspace(user, workspace) do
      role when role in @roles_full_view -> :all
      _role -> non_admin_scope(workspace, user_id, kind)
    end
  end

  # API key / agent identity: inherits the owner's preference.
  def scope(workspace, %{actor: %Dran.Actors.Actor{owner_user_id: owner_id}}, kind)
      when not is_nil(owner_id) do
    agent_scope(workspace, owner_id, kind)
  end

  def scope(workspace, %{actor: %Dran.Actors.Actor{owner_user_id: nil}}, kind) do
    # Unattributable agent: workspace content only. It can never claim
    # someone else's facts, and outside isolation nothing changes (`:all`).
    if shared?(workspace, kind), do: :all, else: {:own, nil}
  end

  def scope(workspace, %{owner_user_id: owner_id} = identity, kind)
      when not is_nil(owner_id) do
    if privileged_identity?(identity) do
      :all
    else
      agent_scope(workspace, owner_id, kind)
    end
  end

  def scope(workspace, %{owner_user_id: nil} = identity, kind) do
    if shared?(workspace, kind) or privileged_identity?(identity), do: :all, else: {:own, nil}
  end

  # Authenticated map without any ownership information — same behaviour the
  # read path had before this feature existed.
  def scope(_workspace, _identity, _kind), do: :all

  @doc """
  Convenience resolver: like `scope/3` but accepting a workspace id, slug or
  struct. Loads the workspace when only an id/slug is given, so every caller
  (REST controller, MCP tool, LiveView) can resolve with what it already has.
  """
  @spec resolve(binary() | map() | struct() | nil, identity(), kind()) :: scope()
  def resolve(workspace, identity, kind)

  def resolve(nil, _identity, _kind), do: :all

  def resolve(%{share_memory: _} = workspace, identity, kind) do
    scope(workspace, identity, kind)
  end

  def resolve(%{share_pages: _} = workspace, identity, kind) do
    scope(workspace, identity, kind)
  end

  def resolve(workspace_id, identity, kind) when is_binary(workspace_id) do
    case Dran.Knowledge.get_workspace_by_slug(workspace_id) ||
           Repo.get(Dran.Workspace, workspace_id) do
      nil -> :all
      workspace -> scope(workspace, identity, kind)
    end
  end

  def resolve(_workspace, _identity, _kind), do: :all

  # ── Query helpers ─────────────────────────────────────────────────────────

  @doc """
  Narrow an Ecto query to a scope, on the given owner column
  (default `:owner_user_id`).

      from(m in Memory) |> ContentVisibility.filter(scope)
  """
  @spec filter(Ecto.Queryable.t(), scope(), atom()) :: Ecto.Queryable.t()
  def filter(queryable, scope, field \\ :owner_user_id)

  def filter(queryable, :all, _field), do: queryable

  def filter(queryable, {:own, owner_id}, field) do
    from(q in queryable, where: field(q, ^field) == ^owner_id)
  end

  @doc """
  Post-fetch check for a single row (graph nodes, cached entries): true when
  a row owned by `owner_user_id` is readable under `scope`.
  """
  @spec visible?(integer() | nil, scope()) :: boolean()
  def visible?(_owner_user_id, :all), do: true
  def visible?(owner_user_id, {:own, expected}), do: owner_user_id == expected

  @doc """
  True when `identity` is a privileged reader of the workspace (owner/admin
  member or instance owner) — the readers that always keep the full view.
  """
  @spec privileged?(map() | struct() | nil, map() | struct() | nil) :: boolean()
  def privileged?(nil, _workspace), do: false
  def privileged?(%{is_owner: true}, _workspace), do: true

  def privileged?(%Dran.Accounts.User{} = user, workspace) do
    Dran.Accounts.user_role_in_workspace(user, workspace) in @roles_full_view
  end

  def privileged?(_identity, _workspace), do: false

  @doc "True when the workspace shares `kind` content across its members."
  @spec shared?(map() | struct(), kind()) :: boolean()
  def shared?(workspace, :memory), do: boolean_field(workspace, :share_memory)

  def shared?(workspace, :pages), do: boolean_field(workspace, :share_pages)

  @doc """
  The personal content preference of `user_id` inside the workspace
  (`"all"` | `"own"`), defaulting to `"all"` when there is no membership row.
  """
  @spec content_scope_for(integer() | nil, binary() | nil) :: String.t()
  def content_scope_for(nil, _workspace_id), do: "all"

  def content_scope_for(user_id, workspace_id) when is_integer(user_id) do
    case workspace_id do
      nil ->
        "all"

      ws_id ->
        case Repo.one(
               from(uw in UserWorkspace,
                 where: uw.user_id == ^user_id and uw.workspace_id == ^ws_id,
                 select: uw.content_scope
               )
             ) do
          scope when scope in @content_scopes -> scope
          _ -> "all"
        end
    end
  end

  # ── Internals ─────────────────────────────────────────────────────────────

  # A user who is not owner/admin: the workspace policy decides. Isolated
  # force-narrows to "solo míos"; shared honours the personal preference.
  defp non_admin_scope(workspace, user_id, kind) do
    if shared?(workspace, kind) do
      case content_scope_for(user_id, workspace_id(workspace)) do
        "own" -> {:own, user_id}
        _ -> :all
      end
    else
      {:own, user_id}
    end
  end

  # An agent reads with the preference of its owner.
  defp agent_scope(workspace, owner_id, kind) do
    if shared?(workspace, kind) do
      case content_scope_for(owner_id, workspace_id(workspace)) do
        "own" -> {:own, owner_id}
        _ -> :all
      end
    else
      {:own, owner_id}
    end
  end

  defp privileged_identity?(identity), do: Map.get(identity, :is_owner) == true

  defp workspace_id(%{id: id}), do: id
  defp workspace_id(_), do: nil

  defp boolean_field(workspace, field) do
    case Map.get(workspace, field) do
      false -> false
      true -> true
      # Column not loaded / map without the key → pre-feature behaviour.
      _ -> true
    end
  end
end
