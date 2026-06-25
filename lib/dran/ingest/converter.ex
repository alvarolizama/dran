defmodule Dran.Ingest.Converter do
  @moduledoc """
  High-level converter that turns uploaded file bytes into a searchable
  markdown note.

  Supported files: PDF, DOCX, PPTX, legacy Word/PowerPoint, and plain text.
  The conversion is delegated to `Dran.Inference.MarkItDown`, then the
  resulting markdown is sanitized before being stored as a page body.
  """

  alias Dran.Inference.ASR
  alias Dran.Inference.MarkItDown
  alias Dran.Inference.Vision
  alias Dran.Uploads

  @audio_mime_types ~w(audio/mpeg audio/mp3 audio/wav audio/x-wav audio/ogg audio/aac audio/webm audio/flac)
  @image_mime_types ~w(image/png image/jpeg image/gif image/webp image/svg+xml)

  @allowed_tags ~w(
    p br h1 h2 h3 h4 h5 h6 hr
    ul ol li
    a img figure figcaption
    strong b em i
    code pre blockquote
    table thead tbody tr th td
    del ins sub sup
  )

  @denied_tag_patterns [
    ~r/<script\b[^>]*>.*?<\/script>/uis,
    ~r/<style\b[^>]*>.*?<\/style>/uis
  ]

  @allowed_tag_pattern Regex.compile!(
                         "^</?(" <> Enum.join(@allowed_tags, "|") <> ")\\b[^>]*>$",
                         "i"
                       )

  @doc """
  Convert an uploaded file to a markdown page body.

  ## Arguments

    * `filename` — original filename (used for the page title and metadata).
    * `mime_type` — MIME type of the file.
    * `bytes` — raw file contents.

  Returns `{:ok, %{title: title, body: markdown}}` or `{:error, reason}`.
  """
  @spec convert(String.t(), String.t(), binary()) ::
          {:ok, %{title: String.t(), body: String.t()}} | {:error, term()}
  def convert(filename, mime_type, bytes)
      when is_binary(filename) and is_binary(mime_type) and is_binary(bytes) do
    max_size = Uploads.max_size()

    cond do
      byte_size(bytes) > max_size ->
        {:error, "file too large (max #{max_size} bytes)"}

      mime_type in @audio_mime_types ->
        with {:ok, transcript} <- ASR.transcribe(bytes, filename) do
          {:ok, %{title: title(filename), body: transcript}}
        end

      mime_type in @image_mime_types ->
        with {:ok, description} <- Vision.describe(bytes) do
          {:ok, %{title: title(filename), body: description}}
        end

      mime_type not in MarkItDown.supported_mime_types() ->
        {:error, "unsupported file type (#{mime_type})"}

      true ->
        with {:ok, markdown} <- MarkItDown.to_markdown(filename, mime_type, bytes) do
          {:ok, %{title: title(filename), body: sanitize(markdown)}}
        end
    end
  end

  @doc """
  Extract a clean title from a filename.
  """
  @spec title(String.t()) :: String.t()
  def title(filename) when is_binary(filename) do
    filename
    |> Path.basename()
    |> Path.rootname()
    |> String.replace(~r/[-_]+/, " ")
    |> String.trim()
    |> case do
      "" -> "untitled"
      other -> other
    end
  end

  @doc """
  Sanitize Markdown-derived HTML.

  Keeps structural and semantic tags necessary for rich markdown rendering
  (headings, lists, links, code, tables) and removes scripts, styles, and
  dangerous URLs such as `javascript:`.
  """
  @spec sanitize(String.t()) :: String.t()
  def sanitize(markdown) when is_binary(markdown) do
    markdown
    |> strip_denied_tags()
    |> strip_disallowed_html_tags()
    |> neutralize_javascript_urls()
    |> normalize_whitespace()
  end

  defp strip_denied_tags(text) do
    Enum.reduce(@denied_tag_patterns, text, fn pattern, acc ->
      Regex.replace(pattern, acc, "")
    end)
  end

  defp strip_disallowed_html_tags(text) do
    Regex.replace(~r/<[^>]+>/u, text, fn tag ->
      if Regex.match?(@allowed_tag_pattern, tag) do
        tag
      else
        ""
      end
    end)
  end

  defp neutralize_javascript_urls(text) do
    Regex.replace(
      ~r/href=["']javascript:/iu,
      text,
      "href=\"blocked:"
    )
  end

  defp normalize_whitespace(text) do
    text
    |> String.replace(~r/\r\n?/, "\n")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end
end
