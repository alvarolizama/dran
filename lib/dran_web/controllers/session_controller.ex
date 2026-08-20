defmodule DranWeb.SessionController do
  @moduledoc """
  Handles login form submission and logout.
  """

  use DranWeb, :controller

  alias Dran.Accounts
  alias DranWeb.Plugs.Auth, as: SessionAuth

  @doc "POST /session — process login form"
  def create(conn, %{"login" => %{"username" => username, "password" => password}}) do
    case Accounts.authenticate_user(username, password) do
      {:ok, user} ->
        conn
        |> SessionAuth.login(user.email)
        |> delete_session(:return_to)
        |> redirect(to: SessionAuth.resolve_login_redirect(conn))

      {:error, _} ->
        conn
        |> put_flash(:error, "Invalid username or password")
        |> redirect(to: ~p"/login")
    end
  end

  @doc "POST /setup — first-run admin creation (only while users table is empty)"
  def setup(conn, %{
        "setup" => %{
          "email" => email,
          "password" => password,
          "password_confirmation" => confirmation
        }
      }) do
    cond do
      Accounts.any_users?() ->
        redirect(conn, to: ~p"/login")

      password != confirmation ->
        conn
        |> put_flash(:error, "Passwords don't match")
        |> redirect(to: ~p"/setup")

      true ->
        case Accounts.create_user_with_password(%{email: email, password: password}) do
          {:ok, user} ->
            {:ok, user} = Accounts.update_user(user, %{is_owner: true})

            conn
            |> SessionAuth.login(user.email)
            |> put_flash(:info, "Owner account created — welcome to Dran")
            |> redirect(to: SessionAuth.resolve_login_redirect(conn))

          {:error, %Ecto.Changeset{} = changeset} ->
            message =
              changeset.errors
              |> Enum.map_join(", ", fn {field, {msg, _}} -> "#{field} #{msg}" end)

            conn
            |> put_flash(:error, message)
            |> redirect(to: ~p"/setup")
        end
    end
  end

  def setup(conn, _params), do: redirect(conn, to: ~p"/setup")

  @doc "DELETE /session — logout"
  def delete(conn, _params) do
    conn
    |> SessionAuth.logout()
    |> redirect(to: ~p"/login")
  end

  @doc "POST /context — switch the active context"
  def switch_workspace(conn, %{"workspace_slug" => workspace_slug}) do
    user_email = get_session(conn, "user")
    user = user_email && Accounts.get_user_by_email(user_email)

    accessible =
      cond do
        is_nil(user) -> :all
        user.is_owner -> :all
        true -> Accounts.list_user_workspaces(user) |> Enum.map(& &1.slug)
      end

    context = Dran.Brain.get_workspace_by_slug(workspace_slug)

    cond do
      is_nil(context) ->
        conn
        |> put_flash(:error, "Unknown context")
        |> redirect(to: ~p"/notes")

      accessible != :all and workspace_slug not in accessible ->
        conn
        |> put_flash(:error, "You don't have access to that context")
        |> redirect(to: ~p"/notes")

      true ->
        conn
        |> SessionAuth.put_workspace(workspace_slug)
        |> redirect(to: referer_path(conn))
    end
  end

  def switch_workspace(conn, _params) do
    conn
    |> put_flash(:error, "Context slug is required")
    |> redirect(to: ~p"/notes")
  end

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
