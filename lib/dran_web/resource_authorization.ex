defmodule DranWeb.ResourceAuthorization do
  @moduledoc """
  Single authorization policy for every non-web surface (REST + MCP).

  One function, `authorize/3`, replaces the per-module variants that had
  drifted apart (`can_write?/2` ×5 and `user_has_context_access?/2` ×5 in
  MCP, the router's `require_write_access`, and the `contexts`-vs-`workspaces`
  naming split). The identity shapes it accepts mirror what the API auth
  pipelines actually produce (see `DranWeb.Router.require_api_token/2`):

    * legacy admin token — `%{is_owner: true, email: "admin", contexts: :all}`
    * per-user token     — `%Dran.Accounts.User{}` (access = members ∪ public)
    * API key            — `%{workspaces: [...], access_levels: %{ws_id => "read" | "write"}, ...}`
    * MCP legacy admin   — `%{is_owner: true, email: "admin", workspaces: :all}`
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

  # ── Owner shapes (legacy token + MCP legacy admin) ────────────────────────

  defp do_authorize(%{is_owner: true}, _mode, _ws_id), do: :ok

  # ── Real user (per-user token): members ∪ public workspaces ───────────────

  defp do_authorize(%Accounts.User{} = user, mode, ws_id) do
    ws = Enum.find(Accounts.accessible_workspaces(user), &(&1.id == ws_id))

    case ws do
      nil ->
        {:error, :forbidden}

      workspace ->
        role = Accounts.user_role_in_workspace(user, workspace)

        if allowed_role?(role, mode), do: :ok, else: {:error, :forbidden}
    end
  end

  # ── API key: per-workspace access levels ──────────────────────────────────

  defp do_authorize(%{access_levels: levels}, mode, ws_id) when is_map(levels) do
    level = Map.get(levels, ws_id)

    case level do
      nil -> {:error, :forbidden}
      level -> if level_allowed?(level, mode), do: :ok, else: {:error, :forbidden}
    end
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
      :read -> role != nil
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
