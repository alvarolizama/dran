defmodule Dran.Auth do
  @moduledoc """
  **Deprecated legacy single-user authentication for Dran.**

  Use `Dran.Accounts` for multi-user auth instead. This module is kept for
  backward compatibility with existing deployments that rely on the
  `DRAN_API_TOKEN` and `DRAN_USERNAME`/`DRAN_PASSWORD` env vars.

  Credentials and config are read from environment variables at startup:

    * `DRAN_USERNAME` — login username (default: `"admin"`)
    * `DRAN_PASSWORD` — login password (default: `"dran"`)
    * `DRAN_API_TOKEN` — bearer token for API/MCP (default: `"dran-token"`)
    * `DRAN_CONTEXT_SLUG` — default context slug (default: `"personal"`)
    * `DRAN_CONTEXT_NAME` — default context display name (default: `"Personal"`)

  ## Deprecated

  The single-user authentication functions on this module — `username/0`,
  `password/0`, `api_token/0`, `valid_credentials?/2` and `valid_token?/1` —
  are superseded by `Dran.Accounts`, which gives each user their own
  `api_token` scoped to their assigned contexts. They are kept functional
  (not removed) so existing single-user deployments keep working.

  `default_context_slug/0` and `default_context_name/0` are startup config
  helpers for the default context and remain supported.
  """

  @username System.get_env("DRAN_USERNAME", "admin")
  @password System.get_env("DRAN_PASSWORD", "dran")
  @api_token System.get_env("DRAN_API_TOKEN", "dran-token")
  @default_context_slug System.get_env("DRAN_CONTEXT_SLUG", "personal")
  @default_context_name System.get_env("DRAN_CONTEXT_NAME", "Personal")

  @doc "Deprecated: use `Dran.Accounts` user records instead."
  def username, do: @username
  @doc "Deprecated: use `Dran.Accounts` user records instead."
  def password, do: @password
  @doc "Deprecated: use each user's `Dran.Accounts` api_token instead."
  def api_token, do: @api_token

  @doc "The default context slug (startup config)."
  def default_context_slug, do: @default_context_slug

  @doc "The default context display name (startup config)."
  def default_context_name, do: @default_context_name

  @doc """
  Deprecated: use `Dran.Accounts` for per-user authentication instead.

  Checks a username/password pair against the configured legacy credentials.
  """
  def valid_credentials?(username, password)
      when is_binary(username) and is_binary(password) do
    username == @username and password == @password
  end

  def valid_credentials?(_, _), do: false

  @doc """
  Deprecated: use `Dran.Accounts.valid_token?/1` instead.

  Checks a bearer token against the configured legacy API token (admin).
  """
  def valid_token?(token) when is_binary(token), do: token == @api_token
  def valid_token?(_), do: false
end
