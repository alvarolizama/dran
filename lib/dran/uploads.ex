defmodule Dran.Uploads do
  @moduledoc """
  Local file storage for uploaded attachments.

  Files are stored content-addressed by sha256 to deduplicate uploads:

      priv/static/uploads/{context_id}/{sha256[:2]}/{sha256}.{ext}

  They are served publicly by `Plug.Static` via the `/uploads` static path.
  """

  @doc "The configured uploads directory (relative to the app root)."
  def dir do
    Application.fetch_env!(:dran, :uploads) |> Keyword.fetch!(:dir)
  end

  @doc "The maximum allowed upload size in bytes."
  def max_size do
    Application.fetch_env!(:dran, :uploads) |> Keyword.fetch!(:max_size)
  end

  @doc "The public URL path where uploads are served."
  def public_path(context_id, sha256, ext) when is_binary(sha256) and is_binary(ext) do
    "/uploads/#{context_id}/#{String.slice(sha256, 0, 2)}/#{sha256}.#{ext}"
  end

  @doc "Computes the sha256 hex of a binary."
  def hash(binary) do
    :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)
  end

  @doc "Extracts a file extension from a filename or client type hint."
  def extension(filename, client_type) when is_binary(filename) do
    ext =
      filename
      |> String.split(".")
      |> List.last()
      |> String.downcase(:ascii)

    if ext in valid_extensions() do
      ext
    else
      ext_from_mime(client_type) || "bin"
    end
  end

  def extension(_, client_type), do: ext_from_mime(client_type) || "bin"

  @doc "Persists an uploaded binary and returns `%{path, sha256, ext, size}`."
  def store(context_id, binary, filename, client_type)
      when is_binary(context_id) and is_binary(binary) do
    sha256 = hash(binary)
    ext = extension(filename, client_type)
    rel_path = "#{context_id}/#{String.slice(sha256, 0, 2)}/#{sha256}.#{ext}"

    uploads_dir = dir()
    abs_path = Path.join([File.cwd!(), uploads_dir, rel_path]) |> Path.expand()
    File.mkdir_p!(Path.dirname(abs_path))

    unless File.exists?(abs_path) do
      File.write!(abs_path, binary)
    end

    %{
      sha256: sha256,
      ext: ext,
      size: byte_size(binary),
      mime_type: client_type,
      filename: filename,
      storage_path: public_path(context_id, sha256, ext)
    }
  end

  defp ext_from_mime("image/png"), do: "png"
  defp ext_from_mime("image/jpeg"), do: "jpg"
  defp ext_from_mime("image/gif"), do: "gif"
  defp ext_from_mime("image/webp"), do: "webp"
  defp ext_from_mime("image/svg+xml"), do: "svg"
  defp ext_from_mime("video/mp4"), do: "mp4"
  defp ext_from_mime("video/webm"), do: "webm"
  defp ext_from_mime("audio/mpeg"), do: "mp3"
  defp ext_from_mime("audio/ogg"), do: "ogg"
  defp ext_from_mime("application/pdf"), do: "pdf"
  defp ext_from_mime("text/plain"), do: "txt"
  defp ext_from_mime("text/markdown"), do: "md"
  defp ext_from_mime("application/zip"), do: "zip"
  defp ext_from_mime(_), do: nil

  defp valid_extensions do
    ~w(png jpg jpeg gif webp svg mp4 webm mov mp3 ogg wav pdf txt md zip csv json html js ts)
  end
end
