defmodule DranWeb.Plugs.Locale do
  @moduledoc """
  Fija el idioma de la petición para Gettext.

  Resolución, de mayor a menor prioridad:

    1. `locale` en la sesión (cambio explícito hecho en esta sesión).
    2. `users.locale` del usuario autenticado — la preferencia durable, que
       sobrevive entre dispositivos.
    3. `Accept-Language` del navegador, solo como pista para visitantes
       anónimos (login, setup, errores).
    4. Inglés, el idioma por defecto de la app.

  El idioma se escribe en el proceso actual (`Gettext.put_locale/2`), que es
  correcto para controllers y para el render muerto de LiveView. El proceso
  del LiveView conectado lo fija por su cuenta en
  `DranWeb.Plugs.Auth.assign_to_socket/3`.
  """

  import Plug.Conn

  alias Dran.Accounts
  alias DranWeb.Gettext, as: Backend

  @session_key "locale"

  def init(opts), do: opts

  def call(conn, _opts) do
    Gettext.put_locale(Backend, locale_for(conn))
    conn
  end

  @doc """
  Idioma efectivo del `conn` según la resolución descrita en el módulo.
  """
  def locale_for(conn) do
    Backend.resolve_locale([
      get_session(conn, @session_key),
      user_locale(conn),
      Backend.from_accept_language(accept_language(conn))
    ])
  end

  @doc "Idioma de la sesión, o `nil` si no se ha cambiado explícitamente."
  def session_locale(conn), do: Backend.normalize_locale(get_session(conn, @session_key))

  defp user_locale(conn) do
    with email when is_binary(email) <- get_session(conn, "user"),
         %{locale: locale} <- Accounts.get_user_by_email(email) do
      Backend.normalize_locale(locale)
    else
      _ -> nil
    end
  end

  defp accept_language(conn) do
    case get_req_header(conn, "accept-language") do
      [header | _] -> header
      _ -> nil
    end
  end
end
