defmodule DranWeb.HTMLSanitizer do
  @moduledoc """
  Sanitizes HTML excerpts produced by PostgreSQL's `ts_headline`.

  `ts_headline` wraps matched search terms in `<b>` tags but does NOT
  HTML-escape the source text. If the underlying body contains HTML
  (e.g. `<script>alert(1)</script>`), that HTML passes through raw and
  creates an XSS risk when rendered with `{raw/1}`.

  This module allows only a small set of safe highlighting tags and
  HTML-escapes everything else, so the `ts_headline` bold markers are
  preserved while any injected markup is neutralized.
  """

  @allowed_tags MapSet.new(~w(b strong em i mark))

  @doc """
  Sanitize an excerpt string, allowing only safe highlighting tags.

  Returns a safe `{:safe, iodata}` tuple suitable for rendering with
  `{raw/1}` or Phoenix.HTML's `safe/1`.

  ## Examples

      iex> DranWeb.HTMLSanitizer.sanitize("hello <b>world</b>")
      {:safe, "hello <b>world</b>"}

      iex> DranWeb.HTMLSanitizer.sanitize("<script>alert(1)</script>")
      {:safe, "&lt;script&gt;alert(1)&lt;/script&gt;"}

      iex> DranWeb.HTMLSanitizer.sanitize("<b>match</b> <img onerror=alert(1)>")
      {:safe, "<b>match</b> &lt;img onerror=alert(1)&gt;"}
  """
  def sanitize(nil), do: {:safe, ""}

  def sanitize(excerpt) when is_binary(excerpt) do
    {:safe, do_sanitize(excerpt)}
  end

  # Public helper for callers that want a plain string (not {:safe, ...}).
  def sanitize_to_string(excerpt) when is_binary(excerpt) or is_nil(excerpt) do
    {:safe, iodata} = sanitize(excerpt)
    IO.iodata_to_binary(iodata)
  end

  defp do_sanitize(<<>>), do: ""

  defp do_sanitize(<<"</", rest::binary>>) do
    case find_close_angle(rest) do
      {:ok, tag_content, after_tag} ->
        tag_name = tag_name(tag_content)

        if MapSet.member?(@allowed_tags, tag_name) and not has_attributes?(tag_content) do
          "</#{tag_name}>" <> do_sanitize(after_tag)
        else
          # Disallowed or has attributes: escape the "<", then continue
          # processing from after the ">" (the ">" will be escaped by the
          # next iteration as "&gt;")
          "&lt;/" <> do_sanitize(tag_content <> ">" <> after_tag)
        end

      :nomatch ->
        # No closing ">" found — escape the "</" and continue
        "&lt;/" <> do_sanitize(rest)
    end
  end

  defp do_sanitize(<<"<", rest::binary>>) do
    case find_close_angle(rest) do
      {:ok, tag_content, after_tag} ->
        tag_name = tag_name(tag_content)

        if MapSet.member?(@allowed_tags, tag_name) and not has_attributes?(tag_content) do
          "<#{tag_name}>" <> do_sanitize(after_tag)
        else
          "&lt;" <> do_sanitize(tag_content <> ">" <> after_tag)
        end

      :nomatch ->
        "&lt;" <> do_sanitize(rest)
    end
  end

  defp do_sanitize(<<char, rest::binary>>) do
    <<escape_char(char)::binary, do_sanitize(rest)::binary>>
  end

  # Find the next ">" in the string.
  # Returns {:ok, content_before, rest_after} or :nomatch.
  defp find_close_angle(binary) do
    case :binary.match(binary, ">") do
      {pos, _len} ->
        before = binary_part(binary, 0, pos)
        after_tag = binary_part(binary, pos + 1, byte_size(binary) - pos - 1)
        {:ok, before, after_tag}

      :nomatch ->
        :nomatch
    end
  end

  # Extract the tag name (first token, lowercased).
  defp tag_name(tag_content) do
    tag_content
    |> String.downcase()
    |> String.trim_trailing("/")
    |> String.split(~r/\s/, parts: 2)
    |> hd()
  end

  # Check if tag content has attributes (anything beyond the tag name).
  defp has_attributes?(tag_content) do
    trimmed = String.trim(tag_content)
    parts = String.split(trimmed, ~r/\s/, parts: 2)
    length(parts) > 1 or String.ends_with?(trimmed, "/")
  end

  # Escape special HTML characters in text content.
  defp escape_char(?<), do: "&lt;"
  defp escape_char(?>), do: "&gt;"
  defp escape_char(?&), do: "&amp;"
  defp escape_char(?"), do: "&quot;"
  defp escape_char(char), do: <<char>>
end
