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
    conn
    |> SessionAuth.put_context(context_slug)
    |> redirect(to: get_req_header(conn, "referer") |> List.first() || ~p"/notes")
  end

  def switch_context(conn, _params) do
    conn
    |> put_flash(:error, "Context slug is required")
    |> redirect(to: ~p"/notes")
  end
end
