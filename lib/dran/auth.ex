defmodule Dran.Auth do
  @moduledoc """
  Single-user authentication for Dran.

  Credentials and config are read from environment variables at startup:

    * `DRAN_USERNAME` — login username (default: `"admin"`)
    * `DRAN_PASSWORD` — login password (default: `"dran"`)
    * `DRAN_API_TOKEN` — bearer token for API/MCP (default: `"dran-token"`)
    * `DRAN_CONTEXT_SLUG` — default context slug (default: `"personal"`)
    * `DRAN_CONTEXT_NAME` — default context display name (default: `"Personal"`)

  This is NOT a multi-user system. The same credentials protect both the
  web UI (session-based) and the REST/MCP API (bearer token).
  """

  @username System.get_env("DRAN_USERNAME", "admin")
  @password System.get_env("DRAN_PASSWORD", "dran")
  @api_token System.get_env("DRAN_API_TOKEN", "dran-token")
  @default_context_slug System.get_env("DRAN_CONTEXT_SLUG", "personal")
  @default_context_name System.get_env("DRAN_CONTEXT_NAME", "Personal")

  def username, do: @username
  def password, do: @password
  def api_token, do: @api_token
  def default_context_slug, do: @default_context_slug
  def default_context_name, do: @default_context_name

  @doc "Checks a username/password pair against the configured credentials."
  def valid_credentials?(username, password)
      when is_binary(username) and is_binary(password) do
    username == @username and password == @password
  end

  def valid_credentials?(_, _), do: false

  @doc "Checks a bearer token against the configured API token."
  def valid_token?(token) when is_binary(token), do: token == @api_token
  def valid_token?(_), do: false
end
