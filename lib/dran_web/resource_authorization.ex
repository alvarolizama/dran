defmodule DranWeb.ResourceAuthorization do
  @moduledoc """
  Single authorization policy for every agent surface (REST + plugin tools).

  One function, `authorize/3`, replaces the per-module variants that had
  drifted apart (`can_write?/2` ×5 and `user_has_context_access?/2` ×5 in
  the retired agent server, the router's `require_write_access`, and the
  `contexts`-vs-`workspaces`
  naming split). The identity shapes it accepts mirror what the API auth
  pipelines actually produce (see `DranWeb.Router.require_api_token/2`):

    * legacy admin token — `%{is_owner: true, email: "admin", contexts: :all}`
    * per-user token     — `%Dran.Accounts.User{}` (access = members ∪ public)
    * account map        — `%{is_owner: ..., instance_role: ..., ...}` (the
      `api_token` credential; same instance-role rule as the struct)
    * legacy admin token — `%{is_owner: true, email: "admin", workspaces: :all}`
    * no user (tests)    — `nil` (fail-open, matching today's behavior)

  Access is decided per workspace and per mode (`:read` | `:write`).
  """

  alias Dran.Accounts

  @type mode :: :read | :write

  @doc """
  Decides whether `user` may perform `mode` operations inside `workspace`.

  `workspace` may be `%Dran.Workspace{}`, a slug, or a workspace id.
  Returns `:ok` or `{:error, :forbidden}`.
  """
  @spec authorize(map() | struct() | nil, mode(), map() | binary() | nil) ::
          :ok | {:error, :forbidden}
  def authorize(nil, _mode, _workspace), do: :ok

  def authorize(user, mode, workspace) do
    case resolve_workspace_id(workspace) do
      nil ->
        {:error, :forbidden}

      ws_id ->
        do_authorize(user, mode, ws_id)
    end
  end

  # ── Owner shapes (legacy admin token) ─────────────────────────────────────

  defp do_authorize(%{is_owner: true}, _mode, _ws_id), do: :ok

  # ── Real user (per-user token): the instance role (W5 single-workspace) ──
  #
  # Every authenticated user reaches the instance; per-item visibility
  # decides WHAT they read, the instance role decides write.

  defp do_authorize(%Accounts.User{} = user, mode, _ws_id) do
    if allowed_role?(user.instance_role, mode), do: :ok, else: {:error, :forbidden}
  end

  # ── API account identity (a map, not a struct) ────────────────────────────
  #
  # The `api_token` credential carries the owner's instance role explicitly;
  # same rule as the struct, applied to the map shape the router assigns.

  defp do_authorize(%{instance_role: role}, mode, _ws_id) when is_binary(role) do
    if allowed_role?(role, mode), do: :ok, else: {:error, :forbidden}
  end

  # ── Legacy `contexts` list maps (fallback; new code should not produce them)

  defp do_authorize(%{contexts: :all}, _mode, _ws_id), do: :ok

  defp do_authorize(%{contexts: contexts}, mode, ws_id) when is_list(contexts) do
    case Enum.find(contexts, &(&1.id == ws_id)) do
      nil -> {:error, :forbidden}
      ws -> mode_allowed?(Map.get(ws, :access_level), mode)
    end
  end

  # Fallback: any other authenticated map — authenticated but not privileged.
  defp do_authorize(_other, _mode, _ws_id), do: {:error, :forbidden}

  # ── Mode rules ────────────────────────────────────────────────────────────

  defp allowed_role?(role, mode) do
    case mode do
      :read -> role in ~w(owner admin editor viewer)
      :write -> role in ~w(owner admin editor)
    end
  end

  defp level_allowed?(level, mode) do
    case mode do
      :read -> level != nil
      :write -> level == "write"
    end
  end

  defp mode_allowed?(level, mode), do: level_allowed?(level, mode)

  @doc """
  Row-level WRITE authority (W3, contract auditoria-fixes): the row-level
  layer the role matrix above never had. Reads resolve their row through the
  reader's scope (no existence leak), but resolving a row never meant owning
  it — "Shares and visibility only move READ access"
  (`Dran.ContentVisibility`, `Dran.Sharing`). `SkillController.can_write?/2`
  was the only surface that enforced it; this is the shared shape for the
  rest.

    * `:all` (privileged reader) writes any row it can read — instance policy.
    * `{:group, gid}` writes exactly what its group can read: the group is a
      PRINCIPAL and the group-shared content IS its own (the decision the
      skills surface already made). The share-grant guard lives in
      `ContentVisibility.filter/3` — a row not actually shared with the group
      never resolved for this reader.
    * `{:reader, id}` writes only rows whose `owner_user_id == id`.
    * anything else (nil scope, malformed row) does NOT write — fail closed.

  `row` is a map or struct carrying at least `:owner_user_id` (tasks carry
  their goal's owner — resolve it before calling).
  """
  @spec can_write_row?(Dran.ContentVisibility.scope(), map() | struct() | nil) :: boolean()
  def can_write_row?(:all, _row), do: true

  def can_write_row?({:group, gid}, row) when is_integer(gid) and is_map(row) do
    Map.get(row, :visibility) == "shared"
  end

  def can_write_row?({:reader, reader_id}, row) when is_integer(reader_id) and is_map(row) do
    Map.get(row, :owner_user_id) == reader_id
  end

  def can_write_row?(_scope, _row), do: false

  # ── Workspace resolution ──────────────────────────────────────────────────

  defp resolve_workspace_id(%Dran.Workspace{id: id}), do: id
  defp resolve_workspace_id(%{id: id}) when is_binary(id), do: id

  defp resolve_workspace_id(slug_or_id) when is_binary(slug_or_id) do
    case Dran.Knowledge.get_workspace_by_slug(slug_or_id) do
      %{id: id} -> id
      # assume an id was passed
      nil -> slug_or_id
    end
  end

  defp resolve_workspace_id(_), do: nil
end
