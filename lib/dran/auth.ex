defmodule Dran.Auth do
  @moduledoc """
  Instance-level auth and default-context helpers, backed by `Dran.Settings`
  (DB) and configurable from `/admin/system`. No environment variables.

    * Admin API token — Settings key `"api_token"`. Legacy bearer token for
      API/MCP (full owner, no user row). Unset = disabled.
    * Default context — Settings keys `"default_workspace_slug"` /
      `"default_workspace_name"`. Used as the fallback workspace slug when a
      user has no session/cookie and no personal default, and as the context
      auto-created by release setup / seeds.

  Web login is handled entirely by `Dran.Accounts` (email + bcrypt password)
  and the first-run `/setup` flow — there are no env-var login credentials.
  """

  @fallback_workspace_slug "personal"

  @doc """
  Bearer token for API/MCP access (legacy admin token).

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
  The default context slug — the settings override, falling back to
  `"personal"` when unset.
  """
  def default_workspace_slug do
    case Dran.Settings.get("default_workspace_slug") do
      slug when is_binary(slug) and slug != "" -> slug
      _ -> @fallback_workspace_slug
    end
  rescue
    _ -> @fallback_workspace_slug
  end

  @doc """
  The default context display name — the settings override, falling back to
  the slug-derived default.
  """
  def default_workspace_name do
    case Dran.Settings.get("default_workspace_name") do
      name when is_binary(name) and name != "" -> name
      _ -> String.capitalize(default_workspace_slug())
    end
  rescue
    _ -> String.capitalize(@fallback_workspace_slug)
  end

  @doc """
  True when the default context was explicitly configured (via /admin/system).
  Only then should the context be auto-created (seeds, release setup) — a
  deleted context stays deleted across deploys when no override is set.
  """
  def default_context_configured? do
    configured =
      not blank?(Dran.Settings.get("default_workspace_slug")) or
        not blank?(Dran.Settings.get("default_workspace_name"))

    configured
  rescue
    _ -> false
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

  # The synthetic user map built by the API auth pipelines carries the key's
  # :actor (a Dran.Actors.Actor) since the actors migration; keys created
  # before that (or without preload) fall back to :key_name. Legacy admin
  # token maps to "system" for owner and "admin" for created_by.
  defp actor_name(user) do
    case Map.get(user, :actor) do
      %Dran.Actors.Actor{name: name} when is_binary(name) -> name
      _ -> Map.get(user, :key_name)
    end
  end

  @doc """
  Resolve the owner identity for a page being created.

  Prefers the API key's actor name; otherwise falls back to the authenticated
  user's email (the literal `"admin"` email maps to `"system"`), then
  `"system"` when no identity is available. Not client-settable.
  """
  def resolve_owner(user) when is_map(user) do
    actor_name(user) ||
      case Map.get(user, :email) do
        "admin" -> "system"
        email when is_binary(email) -> email
        _ -> "system"
      end
  end

  def resolve_owner(_), do: "system"

  @doc """
  Resolve the created_by identity for a page being created.

  For API key auth, uses the key's actor name. For user auth, uses the user
  email. Falls back to "system" when no identity is available.
  """
  def resolve_created_by(user) when is_map(user) do
    actor_name(user) ||
      case Map.get(user, :email) do
        "admin" -> "admin"
        email when is_binary(email) -> email
        _ -> "system"
      end
  end

  def resolve_created_by(_), do: "system"
end
