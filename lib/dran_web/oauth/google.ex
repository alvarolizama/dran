defmodule DranWeb.OAuth.Google do
  @moduledoc """
  Google OAuth 2.0 helper module using Req (no external OAuth libraries).

  Implements the authorization code flow:
    1. `authorize_url/1` — builds the Google consent screen URL.
    2. `exchange_code/1` — exchanges the authorization code for an access token.
    3. `fetch_userinfo/1` — fetches the user's profile from Google's userinfo endpoint.

  Config (via `config :dran, :google_oauth` in runtime.exs):
    * `:client_id`
    * `:client_secret`
    * `:redirect_uri`

  Auto-registration for new Google identities is controlled by the
  `wiki_google_open_signup` setting (per workspace), not by config.
  """

  @auth_url "https://accounts.google.com/o/oauth2/v2/auth"
  @token_url "https://oauth2.googleapis.com/token"
  @userinfo_url "https://www.googleapis.com/oauth2/v2/userinfo"

  @scope "openid email profile"

  @doc """
  Returns the configured Google OAuth settings, or nil if not configured.
  """
  def config do
    Application.get_env(:dran, :google_oauth)
  end

  @doc """
  Returns true if Google OAuth is configured (client_id, client_secret and
  redirect_uri present).
  """
  def configured? do
    cfg = config()
    present?(cfg[:client_id]) and present?(cfg[:client_secret]) and present?(cfg[:redirect_uri])
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_), do: true

  @doc """
  Builds the Google OAuth authorization URL with a CSRF state token.

  The state is stored in the session by the controller to prevent CSRF attacks.
  """
  def authorize_url(state) when is_binary(state) do
    cfg = config!()

    params = %{
      "client_id" => cfg[:client_id],
      "redirect_uri" => cfg[:redirect_uri],
      "response_type" => "code",
      "scope" => @scope,
      "state" => state,
      "prompt" => "select_account"
    }

    @auth_url <> "?" <> URI.encode_query(params)
  end

  @doc """
  Exchanges an authorization code for an access token.

  Returns `{:ok, access_token}` or `{:error, reason}`.
  """
  def exchange_code(code) when is_binary(code) do
    cfg = config!()

    req =
      Req.post!(
        @token_url,
        form: %{
          "code" => code,
          "client_id" => cfg[:client_id],
          "client_secret" => cfg[:client_secret],
          "redirect_uri" => cfg[:redirect_uri],
          "grant_type" => "authorization_code"
        }
      )

    case req.status do
      200 ->
        body = req.body
        access_token = body["access_token"]
        {:ok, access_token}

      _status ->
        {:error, :token_exchange_failed}
    end
  end

  @doc """
  Fetches the user profile from Google's userinfo endpoint.

  Returns `{:ok, %{google_id, email, name, avatar_url}}` or `{:error, reason}`.
  """
  def fetch_userinfo(access_token) when is_binary(access_token) do
    req =
      Req.get!(@userinfo_url,
        headers: %{"Authorization" => "Bearer #{access_token}"}
      )

    case req.status do
      200 ->
        body = req.body

        {:ok,
         %{
           google_id: body["id"],
           email: body["email"],
           name: body["name"],
           avatar_url: body["picture"]
         }}

      _status ->
        {:error, :userinfo_failed}
    end
  end

  defp config! do
    config() || raise "Google OAuth not configured. Set :google_oauth in config."
  end
end
