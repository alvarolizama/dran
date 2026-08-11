defmodule DranWeb.OAuthController do
  @moduledoc """
  Handles Google OAuth 2.0 requests and callbacks.
  """

  use DranWeb, :controller

  alias Dran.Accounts
  alias DranWeb.OAuth.Google
  alias DranWeb.Plugs.Auth, as: SessionAuth

  @doc "GET /auth/google — start the OAuth flow"
  def request(conn, _params) do
    if Google.configured?() do
      state = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

      conn
      |> put_session(:oauth_state, state)
      |> redirect(external: Google.authorize_url(state))
    else
      conn
      |> put_flash(:error, "Google OAuth is not configured")
      |> redirect(to: ~p"/login")
    end
  end

  @doc "GET /auth/google/callback — finish the OAuth flow"
  def callback(conn, %{"code" => code, "state" => state}) do
    stored_state = get_session(conn, :oauth_state)

    if stored_state && state == stored_state do
      conn = delete_session(conn, :oauth_state)
      process_callback(conn, code)
    else
      conn
      |> put_flash(:error, "Invalid OAuth state")
      |> redirect(to: ~p"/login")
    end
  end

  def callback(conn, _params) do
    conn
    |> put_flash(:error, "Invalid OAuth callback")
    |> redirect(to: ~p"/login")
  end

  defp process_callback(conn, code) do
    with {:ok, access_token} <- Google.exchange_code(code),
         {:ok, google_user} <- Google.fetch_userinfo(access_token) do
      handle_google_user(conn, google_user)
    else
      _ ->
        conn
        |> put_flash(:error, "Google authentication failed")
        |> redirect(to: ~p"/login")
    end
  end

  defp handle_google_user(conn, %{email: email} = google_user) do
    case Accounts.find_or_link_from_google(google_user) do
      {:ok, user} ->
        return_to = get_session(conn, :return_to) || ~p"/"

        conn
        |> SessionAuth.login(user.email)
        |> delete_session(:return_to)
        |> redirect(to: return_to)

      {:error, :unauthorized} ->
        # User doesn't exist. If wiki open-signup is enabled, auto-register
        # them as a wiki-only user (no contexts, not admin). Otherwise reject.
        if Dran.Settings.get("wiki_google_open_signup") == true do
          case Accounts.create_user(%{
                 email: email,
                 name: Map.get(google_user, :name),
                 google_id: Map.get(google_user, :google_id),
                 avatar_url: Map.get(google_user, :avatar_url)
               }) do
            {:ok, user} ->
              conn
              |> SessionAuth.login(user.email)
              |> put_flash(:info, "Account created — welcome to the wiki")
              |> redirect(to: ~p"/")

            {:error, _} ->
              conn
              |> put_flash(:error, "Could not create account for #{email}")
              |> redirect(to: ~p"/login")
          end
        else
          conn
          |> put_flash(:error, "No account found for #{email} — ask an admin to create one")
          |> redirect(to: ~p"/login")
        end

      {:error, _} ->
        conn
        |> put_flash(:error, "Could not sign in with #{email}")
        |> redirect(to: ~p"/login")
    end
  end
end
