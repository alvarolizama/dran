defmodule DranWeb.SessionController do
  @moduledoc """
  Handles login form submission and logout.
  """

  use DranWeb, :controller

  alias Dran.Auth
  alias DranWeb.Plugs.Auth, as: SessionAuth

  @doc "POST /session — process login form"
  def create(conn, %{"login" => %{"username" => username, "password" => password}}) do
    if Auth.valid_credentials?(username, password) do
      return_to = get_session(conn, :return_to) || ~p"/notes"

      conn
      |> SessionAuth.login(username)
      |> delete_session(:return_to)
      |> redirect(to: return_to)
    else
      conn
      |> put_flash(:error, "Invalid username or password")
      |> redirect(to: ~p"/login")
    end
  end

  @doc "DELETE /session — logout"
  def delete(conn, _params) do
    conn
    |> SessionAuth.logout()
    |> redirect(to: ~p"/login")
  end

  @doc "POST /context — switch the active context"
  def switch_context(conn, %{"context_slug" => context_slug}) do
    user_email = get_session(conn, "user")
    user = user_email && Dran.Accounts.get_user_by_email(user_email)

    accessible =
      cond do
        is_nil(user) -> :all
        user.is_admin -> :all
        true -> Dran.Accounts.list_user_contexts(user) |> Enum.map(& &1.slug)
      end

    context = Dran.Brain.get_context_by_slug(context_slug)

    cond do
      is_nil(context) ->
        conn
        |> put_flash(:error, "Unknown context")
        |> redirect(to: ~p"/notes")

      accessible != :all and context_slug not in accessible ->
        conn
        |> put_flash(:error, "You don't have access to that context")
        |> redirect(to: ~p"/notes")

      true ->
        conn
        |> SessionAuth.put_context(context_slug)
        |> redirect(to: referer_path(conn))
    end
  end

  def switch_context(conn, _params) do
    conn
    |> put_flash(:error, "Context slug is required")
    |> redirect(to: ~p"/notes")
  end

  # Extracts the path (and query) from the Referer header so `redirect(to:)`
  # receives a local path, not a full URL. Falls back to "/notes".
  defp referer_path(conn) do
    case get_req_header(conn, "referer") |> List.first() do
      nil ->
        ~p"/notes"

      url ->
        case URI.parse(url) do
          %URI{path: path} when is_binary(path) and path != "" ->
            case URI.parse(url).query do
              nil -> path
              query -> path <> "?" <> query
            end

          _ ->
            ~p"/notes"
        end
    end
  end
end
