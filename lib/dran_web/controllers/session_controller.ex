defmodule DranWeb.SessionController do
  @moduledoc """
  Handles login form submission and logout.
  """

  use DranWeb, :controller

  alias Dran.Accounts
  alias DranWeb.Plugs.Auth, as: SessionAuth

  @doc "POST /session — process login form"
  def create(conn, %{"login" => %{"username" => username, "password" => password}}) do
    # Failure-based throttle, two layers (see DranWeb.LoginThrottle): the
    # submitted identifier (proxy-independent) and the client IP. Both are
    # checked BEFORE authenticate_user so a throttled attempt costs no bcrypt
    # work. conn.remote_ip is the real client because DranWeb.Plugs.ClientIp
    # rewrote it from x-forwarded-for in the :browser pipeline.
    with :ok <- DranWeb.LoginThrottle.check(username),
         :ok <- DranWeb.LoginThrottle.check_ip(client_ip(conn)) do
      do_login(conn, username, password)
    else
      {:error, :throttled} ->
        conn
        |> put_flash(:error, "Too many failed attempts. Try again later.")
        |> redirect(to: ~p"/login")
    end
  end

  defp do_login(conn, username, password) do
    case Accounts.authenticate_user(username, password) do
      {:ok, user} ->
        # Only the identifier is cleared: an IP is shared by other users, so
        # clearing it would erase their failure history.
        DranWeb.LoginThrottle.clear(username)

        conn
        |> SessionAuth.login(user.email)
        |> delete_session(:return_to)
        |> redirect(to: SessionAuth.resolve_login_redirect(conn))

      {:error, _} ->
        DranWeb.LoginThrottle.record_failure(username)
        DranWeb.LoginThrottle.record_failure_ip(client_ip(conn))

        conn
        |> put_flash(:error, "Invalid username or password")
        |> redirect(to: ~p"/login")
    end
  end

  defp client_ip(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()

  @doc "POST /setup — first-run admin creation (only while users table is empty)"
  def setup(conn, %{"setup" => params}) do
    cond do
      Accounts.any_users?() ->
        redirect(conn, to: ~p"/login")

      params["password"] != params["password_confirmation"] ->
        conn
        |> put_flash(:error, "Passwords don't match")
        |> redirect(to: ~p"/setup")

      true ->
        # Los params van tal cual al changeset (con claves string), que es como
        # los mandó el navegador: así el nombre y la contraseña se validan en un
        # solo sitio y el error se puede leer en el flash. El owner nace con
        # nombre porque su workspace personal se llama como él (y su URL sale
        # de ahí, no del correo).
        case Accounts.create_user_with_password(params) do
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
end
