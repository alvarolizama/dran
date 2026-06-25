defmodule Dran.Inference.ASR do
  @moduledoc """
  Audio transcription using the configured ASR model.

  Sends audio bytes to `/v1/audio/transcriptions` as multipart/form-data and
  returns the transcript.
  """

  alias Dran.Inference.{Client, Config}

  @doc """
  Transcribe raw audio bytes.
  """
  @spec transcribe(binary(), String.t()) :: Client.result(String.t())
  def transcribe(bytes, filename \\ "audio.mp3") when is_binary(bytes) do
    case Config.enabled?() do
      false ->
        {:error, :not_configured}

      true ->
        Dran.Inference.Queue.run(:audio, fn ->
          do_transcribe(bytes, filename)
        end)
    end
  end

  @doc """
  Transcribe audio from a local file path.
  """
  @spec transcribe_path(String.t()) :: Client.result(String.t())
  def transcribe_path(path) when is_binary(path) do
    case File.read(path) do
      {:ok, bytes} -> transcribe(bytes, Path.basename(path))
      {:error, reason} -> {:error, {:read_error, reason}}
    end
  end

  defp do_transcribe(bytes, filename) do
    boundary = generate_boundary()

    body =
      [
        multipart_part("model", Config.asr_model(), boundary),
        multipart_file_part("file", filename, bytes, boundary),
        "--#{boundary}--\r\n"
      ]
      |> IO.iodata_to_binary()

    client_opts = [
      body: body,
      headers: [{"content-type", "multipart/form-data; boundary=#{boundary}"}]
    ]

    case Client.request(:post, "/audio/transcriptions", client_opts) do
      {:ok, response} -> {:ok, Map.get(response, "text", "")}
      {:error, reason} -> {:error, reason}
    end
  end

  defp generate_boundary do
    "DranBoundary" <> (16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))
  end

  defp multipart_part(name, value, boundary) do
    [
      "--#{boundary}\r\n",
      "content-disposition: form-data; name=\"#{name}\"\r\n\r\n",
      value,
      "\r\n"
    ]
  end

  defp multipart_file_part(name, filename, bytes, boundary) do
    [
      "--#{boundary}\r\n",
      "content-disposition: form-data; name=\"#{name}\"; filename=\"#{filename}\"\r\n",
      "content-type: application/octet-stream\r\n\r\n",
      bytes,
      "\r\n"
    ]
  end
end
