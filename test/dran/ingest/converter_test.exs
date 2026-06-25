defmodule Dran.Ingest.ConverterTest do
  use ExUnit.Case, async: false

  alias Dran.Ingest.Converter

  setup do
    original = Application.get_env(:dran, :inference)

    Application.put_env(:dran, :inference,
      base_url: "http://localhost:8000/v1",
      api_key: "test-key",
      markitdown_model: "MarkItDown",
      asr_model: "Qwen3-ASR",
      vision_model: "Qwen3.6-35B-A3B",
      timeout: 5_000,
      req_plug: {Req.Test, Dran.Inference.Client}
    )

    ensure_queue_started(:markdown)
    ensure_queue_started(:audio)
    ensure_queue_started(:vision)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:dran, :inference)
      else
        Application.put_env(:dran, :inference, original)
      end
    end)

    :ok
  end

  test "rejects files that are too large" do
    max_size = Dran.Uploads.max_size()
    big = String.duplicate("x", max_size + 1)

    assert {:error, _reason} = Converter.convert("big.txt", "text/plain", big)
  end

  test "rejects unsupported binary file types" do
    assert {:error, "unsupported file type (application/x-msdownload)"} =
             Converter.convert("x.exe", "application/x-msdownload", <<1, 2, 3>>)
  end

  test "converts supported text/markdown files through MarkItDown" do
    Req.Test.stub(Dran.Inference.Client, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)

      case decoded["model"] do
        "MarkItDown" ->
          Req.Test.json(conn, %{
            "choices" => [%{"message" => %{"content" => "# Report\n\nContents."}}]
          })

        _ ->
          Req.Test.json(conn, %{
            "choices" => [%{"message" => %{"content" => "unused"}}]
          })
      end
    end)

    assert {:ok, %{title: "report", body: body}} =
             Converter.convert("report.txt", "text/plain", "hello world")

    assert body =~ "# Report"
  end

  test "transcribes audio files" do
    Req.Test.stub(Dran.Inference.Client, fn conn ->
      assert conn.request_path == "/v1/audio/transcriptions"
      Req.Test.json(conn, %{"text" => "Hello from audio"})
    end)

    assert {:ok, %{title: "podcast", body: "Hello from audio"}} =
             Converter.convert("podcast.mp3", "audio/mpeg", <<1, 2, 3>>)
  end

  test "describes image files" do
    Req.Test.stub(Dran.Inference.Client, fn conn ->
      assert conn.request_path == "/v1/chat/completions"

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)
      assert decoded["model"] == "Qwen3.6-35B-A3B"

      Req.Test.json(conn, %{
        "choices" => [%{"message" => %{"content" => "A screenshot of code"}}]
      })
    end)

    png = <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, "IHDR">>

    assert {:ok, %{title: "screenshot", body: "A screenshot of code"}} =
             Converter.convert("screenshot.png", "image/png", png)
  end

  defp ensure_queue_started(capability) do
    case Registry.start_link(keys: :unique, name: Dran.Inference.QueueRegistry) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    case Dran.Inference.Queue.start_link(capability: capability) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end
end
