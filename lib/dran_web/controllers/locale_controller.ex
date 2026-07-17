defmodule DranWeb.LocaleController do
  use DranWeb, :controller

  def set(conn, %{"locale" => locale}) when locale in ["en", "es"] do
    conn
    |> put_session(:locale, locale)
    |> redirect(to: get_referer_path(conn))
  end

  def set(conn, _params) do
    conn
    |> put_flash(:error, "Invalid locale")
    |> redirect(to: ~p"/")
  end

  defp get_referer_path(conn) do
    case get_req_header(conn, "referer") do
      [referer] ->
        uri = URI.parse(referer)
        uri.path || "/"

      _ ->
        "/"
    end
  end
end
