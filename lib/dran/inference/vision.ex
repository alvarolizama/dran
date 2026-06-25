defmodule Dran.Inference.Vision do
  @moduledoc """
  Image understanding using the configured chat/vision model.

  Sends an image as base64 to `/v1/chat/completions` and returns the
  model's description.
  """

  alias Dran.Inference.{Client, Config}

  @doc """
  Describe an image from raw bytes.

  Returns `{:ok, description}` or `{:error, reason}`.
  """
  @spec describe(binary(), String.t()) :: Client.result(String.t())
  def describe(bytes, prompt \\ "Describe this image in detail.") when is_binary(bytes) do
    mime = mime_type(bytes)
    base64 = Base.encode64(bytes)

    describe_url("data:#{mime};base64,#{base64}", prompt)
  end

  @doc """
  Describe an image from a base64 data URL or public URL.
  """
  @spec describe_url(String.t(), String.t()) :: Client.result(String.t())
  def describe_url(image_url, prompt \\ "Describe this image in detail.")
      when is_binary(image_url) do
    case Config.enabled?() do
      false ->
        {:error, :not_configured}

      true ->
        Dran.Inference.Queue.run(:vision, fn ->
          payload = %{
            "model" => Config.vision_model(),
            "messages" => [
              %{
                "role" => "user",
                "content" => [
                  %{"type" => "text", "text" => prompt},
                  %{"type" => "image_url", "image_url" => %{"url" => image_url}}
                ]
              }
            ],
            "temperature" => 0.3,
            "max_tokens" => 2_000
          }

          case Client.chat(payload) do
            {:ok, %{} = message} -> {:ok, Map.get(message, "content", "")}
            {:error, reason} -> {:error, reason}
          end
        end)
    end
  end

  @doc """
  Describe an image from a local file path.
  """
  @spec describe_path(String.t(), String.t()) :: Client.result(String.t())
  def describe_path(path, prompt \\ "Describe this image in detail.") when is_binary(path) do
    case File.read(path) do
      {:ok, bytes} -> describe(bytes, prompt)
      {:error, reason} -> {:error, {:read_error, reason}}
    end
  end

  defp mime_type(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _::binary>>), do: "image/png"
  defp mime_type(<<0xFF, 0xD8, _::binary>>), do: "image/jpeg"
  defp mime_type(<<"GIF87a", _::binary>>), do: "image/gif"
  defp mime_type(<<"GIF89a", _::binary>>), do: "image/gif"
  defp mime_type(<<"RIFF", _, _, _, "WEBP", _::binary>>), do: "image/webp"
  defp mime_type(_), do: "image/jpeg"
end
