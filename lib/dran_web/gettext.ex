defmodule DranWeb.Gettext do
  @moduledoc """
  Backend de internacionalización de la app.

  ## Idioma

  El **inglés es el idioma por defecto** (`default_locale: "en"`): los `msgid`
  del código están escritos en inglés y son la red de seguridad cuando falta
  una traducción. El español es el idioma **secundario**, con catálogo propio
  en `priv/gettext/es`.

  La preferencia por usuario vive en el campo `users.locale` (ver
  `Dran.Accounts.User`) y se resuelve en dos puntos:

    * `DranWeb.Plugs.Locale` — peticiones HTTP (controllers y render muerto).
    * `DranWeb.Plugs.Auth.assign_to_socket/3` — cada LiveView, que corre en su
      propio proceso y por eso necesita fijar el locale él mismo.

  Uso desde el código:

      use Gettext, backend: DranWeb.Gettext

      gettext("Here is the string to translate")
      ngettext("One item", "Many items", 3)
      dgettext("errors", "Here is the error message to translate")

  Ver la [documentación de Gettext](https://hexdocs.pm/gettext) para más detalle.
  """

  use Gettext.Backend, otp_app: :dran, default_locale: "en"

  # Idiomas con catálogo propio, en orden de preferencia para la UI
  # (el primero es el que se ofrece por defecto).
  @supported_locales ~w(en es)

  @doc "Idiomas soportados, el primero es el preferido por defecto."
  def supported_locales, do: @supported_locales

  @doc "Idioma por defecto de la app."
  def app_default_locale, do: "en"

  @doc """
  Normaliza una etiqueta de idioma arbitraria (`"en-US"`, `"ES"`, `"es_ES"`)
  al idioma soportado correspondiente, o `nil` si no hay ninguno.

      iex> DranWeb.Gettext.normalize_locale("es-MX")
      "es"

      iex> DranWeb.Gettext.normalize_locale("fr")
      nil
  """
  def normalize_locale(nil), do: nil

  def normalize_locale(tag) when is_binary(tag) do
    base =
      tag
      |> String.trim()
      |> String.downcase()
      |> String.split(~r/[-_]/, parts: 2)
      |> List.first()

    if base in @supported_locales, do: base
  end

  def normalize_locale(_), do: nil

  @doc """
  Resuelve el primer idioma válido de una lista de candidatos
  (preferencia del usuario, `Accept-Language`, …) cayendo al idioma por
  defecto de la app.

      iex> DranWeb.Gettext.resolve_locale([nil, "fr", "es"])
      "es"

      iex> DranWeb.Gettext.resolve_locale([])
      "en"
  """
  def resolve_locale(candidates) when is_list(candidates) do
    Enum.find_value(candidates, app_default_locale(), &normalize_locale/1)
  end

  @doc """
  Interpreta una cabecera `Accept-Language` y devuelve el mejor idioma
  soportado, o `nil` si ninguno encaja.

  Ignora los pesos (`q=`) y respeta el orden de preferencia.
  """
  def from_accept_language(nil), do: nil

  def from_accept_language(header) when is_binary(header) do
    header
    |> String.split(",")
    |> Enum.map(fn part ->
      part
      |> String.split(";", parts: 2)
      |> List.first()
      |> String.trim()
    end)
    |> Enum.find_value(&normalize_locale/1)
  end

  def from_accept_language(_), do: nil
end
