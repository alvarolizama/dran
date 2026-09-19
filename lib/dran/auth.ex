defmodule Dran.Auth do
  @moduledoc """
  Instance-level auth and default-context helpers, backed by `Dran.Settings`
  (DB) and configurable from `/admin/system`. No environment variables.

    * Admin API token — Settings key `"api_token"`. Legacy bearer token for
      API/agent access (full owner, no user row). Unset = disabled.
    * Default context — the workspace flagged as default (`is_default`, set from
      /admin/workspaces), with the legacy Settings keys
      `"default_workspace_slug"` / `"default_workspace_name"` as fallback. Used
      as the workspace slug when a user has no session/cookie and no personal
      default, and as the context auto-created by release setup / seeds.

  Web login is handled entirely by `Dran.Accounts` (email + bcrypt password)
  and the first-run `/setup` flow — there are no env-var login credentials.
  """

  @fallback_workspace_slug "personal"

  @doc """
  Bearer token for API/agent access (legacy admin token).

  Stored in the `settings` table; unset means the legacy admin token is
  DISABLED (fail closed on DB errors too). Generate or rotate it from
  /admin/system.
  """
  def api_token do
    Dran.Settings.get("api_token")
  rescue
    _ -> nil
  end

  @doc "Generates a random URL-safe token for the legacy admin bearer."
  def generate_token do
    :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
  end

  @doc """
  The default context slug, resolved in this order:

    1. the workspace flagged as the instance default (`is_default = true`,
       toggled from /admin/workspaces),
    2. the legacy settings override `"default_workspace_slug"` — kept as a
       fallback for installs configured before the flag became the control,
    3. the built-in `"personal"`.
  """
  def default_workspace_slug do
    case default_workspace() do
      %{slug: slug} when is_binary(slug) and slug != "" -> slug
      _ -> configured_workspace_slug()
    end
  end

  @doc """
  The default context display name: the flagged default's name, else the
  legacy settings override, else the slug-derived default.
  """
  def default_workspace_name do
    case default_workspace() do
      %{name: name} when is_binary(name) and name != "" -> name
      _ -> configured_workspace_name()
    end
  end

  @doc """
  True when the default context was explicitly configured — a workspace carries
  the default flag, or a legacy settings override is set. Only then should the
  context be auto-created (seeds, release setup): a deleted context stays
  deleted across deploys when nothing is configured.
  """
  def default_workspace_configured? do
    not is_nil(default_workspace()) or
      not blank?(Dran.Settings.get("default_workspace_slug")) or
      not blank?(Dran.Settings.get("default_workspace_name"))
  rescue
    _ -> false
  end

  # The flagged default lives in the DB: a missing or unavailable repo must
  # never break resolution — the settings fallback and "personal" still answer.
  defp default_workspace do
    Dran.Knowledge.get_default_workspace()
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp configured_workspace_slug do
    case Dran.Settings.get("default_workspace_slug") do
      slug when is_binary(slug) and slug != "" -> slug
      _ -> @fallback_workspace_slug
    end
  rescue
    _ -> @fallback_workspace_slug
  end

  defp configured_workspace_name do
    case Dran.Settings.get("default_workspace_name") do
      name when is_binary(name) and name != "" -> name
      _ -> String.capitalize(configured_workspace_slug())
    end
  rescue
    _ -> String.capitalize(configured_workspace_slug())
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  @doc """
  Checks a bearer token against the configured legacy API token (admin).
  """
  def valid_token?(token) when is_binary(token), do: token == api_token()
  def valid_token?(_), do: false

  # ── Owner / created_by resolution ──

  # The synthetic user map built by the API auth pipelines carries the KEY as
  # the agent identity (W3): `:key_name` is `api_keys.name`, and `:agent_name`
  # is the X-Hermes-Agent header — resolved in ONE place
  # (`DranWeb.Router.require_api_token/2`), never re-derived here.
  # Legacy admin token maps to "system" for owner and "admin" for created_by.
  defp key_name(user), do: Map.get(user, :key_name)

  @doc """
  Resolve the owner identity for a page being created.

  Prefers the API key name; otherwise falls back to the authenticated user's
  email (the literal `"admin"` email maps to `"system"`), then `"system"` when
  no identity is available. Not client-settable.
  """
  def resolve_owner(user) when is_map(user) do
    key_name(user) ||
      case Map.get(user, :email) do
        "admin" -> "system"
        email when is_binary(email) -> email
        _ -> "system"
      end
  end

  def resolve_owner(_), do: "system"

  @doc """
  Resolve the created_by identity for a page being created.

  For API key auth: the `X-Hermes-Agent` header when it came, otherwise the
  key `name` (M7). For user auth, the user email. Falls back to `"system"`
  when no identity is available.
  """
  def resolve_created_by(user) when is_map(user) do
    Map.get(user, :agent_name) ||
      key_name(user) ||
      case Map.get(user, :email) do
        "admin" -> "admin"
        email when is_binary(email) -> email
        _ -> "system"
      end
  end

  def resolve_created_by(_), do: "system"

  @doc """
  Resolve the OWNER user id for content being written — the user that owns the
  agent behind the request. Injected server-side, never client-settable.

  * API key identity — `api_keys.created_by_user_id` (the user that created
    the key), or `nil` for keys with no creator (historical / system-created
    keys). The actor is no longer part of this chain (W3).
  * user identity (`%Dran.Accounts.User{}`) — that user.
  * legacy admin token / `nil` — `nil`: historical producer content is
    workspace-wide (see `Dran.ContentVisibility`).
  """
  def resolve_owner_user_id(%Dran.Accounts.User{id: id}), do: id

  def resolve_owner_user_id(user) when is_map(user) do
    Map.get(user, :created_by_user_id)
  end

  def resolve_owner_user_id(_), do: nil

  @doc """
  Extract the Hermes profile name from the request headers
  (`X-Hermes-Agent`), or `nil` when absent. Plug lowercases header names.

  It is attribution, not authorization: the value is persisted as
  `agent_name` on the written content and never widens access.
  """
  def agent_name_from_headers(headers) when is_list(headers) do
    Enum.find_value(headers, fn
      {"x-hermes-agent", value} when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> String.slice(trimmed, 0, 120)
        end

      _ ->
        nil
    end)
  end

  def agent_name_from_headers(_), do: nil
end
