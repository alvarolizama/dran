defmodule DranWeb.OAuth.Google do
  @moduledoc """
  Google OAuth 2.0 for Dran — visible only when env vars are set.

  Config via env vars:
    * `GOOGLE_CLIENT_ID`
    * `GOOGLE_CLIENT_SECRET`
    * `GOOGLE_REDIRECT_URI` (default: derived from endpoint URL)
  """

  @auth_url "https://accounts.google.com/o/oauth2/v2/auth"
  @token_url "https://oauth2.googleapis.com/token"
  @userinfo_url "https://www.googleapis.com/oauth2/v2/userinfo"
  @scope "openid email profile"

  def configured? do
    present?(client_id()) and present?(client_secret())
  end

  def client_id, do: System.get_env("GOOGLE_CLIENT_ID")
  def client_secret, do: System.get_env("GOOGLE_CLIENT_SECRET")

  def redirect_uri do
    System.get_env("GOOGLE_REDIRECT_URI") ||
      DranWeb.Endpoint.url() <> "/auth/google/callback"
  end

  def authorize_url(state) when is_binary(state) do
    params = %{
      "client_id" => client_id(),
      "redirect_uri" => redirect_uri(),
      "response_type" => "code",
      "scope" => @scope,
      "state" => state,
      "prompt" => "select_account"
    }

    @auth_url <> "?" <> URI.encode_query(params)
  end

  def exchange_code(code) when is_binary(code) do
    req =
      Req.post!(@token_url,
        form: %{
          "code" => code,
          "client_id" => client_id(),
          "client_secret" => client_secret(),
          "redirect_uri" => redirect_uri(),
          "grant_type" => "authorization_code"
        }
      )

    case req.status do
      200 -> {:ok, req.body["access_token"]}
      _ -> {:error, :token_exchange_failed}
    end
  end

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

      _ ->
        {:error, :userinfo_failed}
    end
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_), do: true
end
