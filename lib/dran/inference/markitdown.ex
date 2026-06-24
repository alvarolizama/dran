defmodule Dran.Inference.MarkItDown do
  @moduledoc """
  Converts files (PDF, DOCX, PPTX, TXT) to Markdown using the `MarkItDown`
  model through the OpenAI-compatible chat completions endpoint.
  """

  alias Dran.Inference.{Client, Config}

  @supported_mime_types ~w(
    application/pdf
    application/vnd.openxmlformats-officedocument.wordprocessingml.document
    application/vnd.openxmlformats-officedocument.presentationml.presentation
    application/vnd.ms-powerpoint
    application/msword
    text/plain
  )

  @doc """
  Returns the list of MIME types the converter accepts.
  """
  @spec supported_mime_types() :: list(String.t())
  def supported_mime_types, do: @supported_mime_types

  @doc """
  Convert a file's bytes to markdown.

  ## Arguments

  - `filename` — original filename, used only as metadata for the model.
  - `mime_type` — MIME type of the file.
  - `bytes` — raw file contents.

  Returns `{:ok, markdown_string}` or `{:error, reason}`.
  """
  @spec to_markdown(String.t(), String.t(), binary()) :: {:ok, String.t()} | {:error, term()}
  def to_markdown(filename, mime_type, bytes)
      when is_binary(filename) and is_binary(mime_type) and is_binary(bytes) do
    if mime_type in @supported_mime_types do
      payload = %{
        "model" => Config.markitdown_model(),
        "messages" => [
          %{
            "role" => "user",
            "content" => [
              %{"type" => "text", "text" => "Convert this file to Markdown."},
              %{
                "type" => "file",
                "file" => %{
                  "filename" => filename,
                  "file_data" => Base.encode64(bytes),
                  "content_type" => mime_type
                }
              }
            ]
          }
        ]
      }

      case Client.chat(payload) do
        {:ok, %{"content" => content}} when is_binary(content) ->
          {:ok, content}

        {:ok, message} ->
          {:error, {:unexpected_response, message}}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :unsupported_mime_type}
    end
  end

  @doc """
  Convenience function that reads a local file and converts it.
  """
  @spec from_path(String.t()) :: {:ok, String.t()} | {:error, term()}
  def from_path(path) when is_binary(path) do
    case File.read(path) do
      {:ok, bytes} ->
        mime = mime_type_for(Path.extname(path))
        to_markdown(Path.basename(path), mime, bytes)

      {:error, reason} ->
        {:error, {:read_error, reason}}
    end
  end

  defp mime_type_for(".pdf"), do: "application/pdf"

  defp mime_type_for(".docx"),
    do: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

  defp mime_type_for(".pptx"),
    do: "application/vnd.openxmlformats-officedocument.presentationml.presentation"

  defp mime_type_for(".ppt"), do: "application/vnd.ms-powerpoint"
  defp mime_type_for(".doc"), do: "application/msword"
  defp mime_type_for(".txt"), do: "text/plain"
  defp mime_type_for(_), do: "application/octet-stream"
end
