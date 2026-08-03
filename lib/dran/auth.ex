defmodule Dran.Auth do
  @moduledoc """
  Startup config helpers for Dran: MCP/API token and default context.

  Web login is handled entirely by `Dran.Accounts` (email + bcrypt password)
  and the first-run `/setup` flow — there are no env-var login credentials.

  Config read from environment variables at startup:

    * `DRAN_API_TOKEN` — bearer token for API/MCP (default: `"dran-token"`)
    * `DRAN_CONTEXT_SLUG` — default context slug (default: `"personal"`)
    * `DRAN_CONTEXT_NAME` — default context display name (default: `"Personal"`)
  """

  @api_token System.get_env("DRAN_API_TOKEN", "dran-token")
  @default_context_slug System.get_env("DRAN_CONTEXT_SLUG", "personal")
  @default_context_name System.get_env("DRAN_CONTEXT_NAME", "Personal")

  @doc "Bearer token for API/MCP access (legacy admin token)."
  def api_token, do: @api_token

  @doc "The default context slug (startup config)."
  def default_context_slug, do: @default_context_slug

  @doc "The default context display name (startup config)."
  def default_context_name, do: @default_context_name

  @doc """
  Checks a bearer token against the configured legacy API token (admin).
  """
  def valid_token?(token) when is_binary(token), do: token == @api_token
  def valid_token?(_), do: false
end
