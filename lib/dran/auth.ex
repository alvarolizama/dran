defmodule Dran.Auth do
  @moduledoc """
  Startup config helpers for Dran: MCP/API token and default context.

  Web login is handled entirely by `Dran.Accounts` (email + bcrypt password)
  and the first-run `/setup` flow — there are no env-var login credentials.

  Config read from environment variables at startup:

    * `DRAN_API_TOKEN` — bearer token for API/MCP (default: `"dran-token"`)
    * `DRAN_WORKSPACE_SLUG` — default context slug (default: `"personal"`)
    * `DRAN_WORKSPACE_NAME` — default context display name (default: `"Personal"`)

  The default context is only auto-created (release setup / seeds) when at
  least one of `DRAN_WORKSPACE_SLUG` / `DRAN_WORKSPACE_NAME` is explicitly set.
  """

  @api_token System.get_env("DRAN_API_TOKEN", "dran-token")
  @default_workspace_slug System.get_env("DRAN_WORKSPACE_SLUG", "personal")
  @default_workspace_name System.get_env("DRAN_WORKSPACE_NAME", "Personal")

  @doc "Bearer token for API/MCP access (legacy admin token)."
  def api_token, do: @api_token

  @doc "The default context slug (startup config)."
  def default_workspace_slug, do: @default_workspace_slug

  @doc "The default context display name (startup config)."
  def default_workspace_name, do: @default_workspace_name

  @doc """
  True when the default context was explicitly configured via
  `DRAN_WORKSPACE_SLUG` and/or `DRAN_WORKSPACE_NAME`. Only then should the
  context be auto-created (seeds, release setup).

  Read at runtime (not compile time) so release `eval` commands and tests
  honour the environment they're actually running with.
  """
  def default_context_configured? do
    System.get_env("DRAN_WORKSPACE_SLUG") != nil or System.get_env("DRAN_WORKSPACE_NAME") != nil
  end

  @doc """
  Checks a bearer token against the configured legacy API token (admin).
  """
  def valid_token?(token) when is_binary(token), do: token == @api_token
  def valid_token?(_), do: false

  # ── Owner / created_by resolution ──

  @doc """
  Resolve the owner identity for a page being created.

  Prefers the API key name; otherwise falls back to the authenticated
  user's email (the literal `"admin"` email maps to `"system"`), then
  `"system"` when no identity is available. Not client-settable.
  """
  def resolve_owner(user) when is_map(user) do
    Map.get(user, :key_name) ||
      case Map.get(user, :email) do
        "api-key:" <> _ = email -> email
        "admin" -> "system"
        email when is_binary(email) -> email
        _ -> "system"
      end
  end

  def resolve_owner(_), do: "system"

  @doc """
  Resolve the created_by identity for a page being created.

  For API key auth, uses the key name. For user auth, uses the user email.
  Falls back to "system" when no identity is available.
  """
  def resolve_created_by(user) when is_map(user) do
    Map.get(user, :key_name) ||
      case Map.get(user, :email) do
        "api-key:" <> _ = email -> email
        "admin" -> "admin"
        email when is_binary(email) -> email
        _ -> "system"
      end
  end

  def resolve_created_by(_), do: "system"
end
