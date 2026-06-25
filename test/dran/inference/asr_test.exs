defmodule Dran.Inference.ASRTest do
  use ExUnit.Case, async: false

  alias Dran.Inference.ASR
  alias Dran.Inference.Queue

  setup do
    original = Application.get_env(:dran, :inference)

    Application.put_env(:dran, :inference,
      base_url: "http://localhost:8000/v1",
      api_key: "test-key",
      asr_model: "Qwen3-ASR",
      timeout: 5_000,
      req_plug: {Req.Test, Dran.Inference.Client}
    )

    ensure_queue_started(:audio)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:dran, :inference)
      else
        Application.put_env(:dran, :inference, original)
      end
    end)

    :ok
  end

  test "transcribe/2 returns text from the ASR endpoint" do
    Req.Test.stub(Dran.Inference.Client, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/audio/transcriptions"

      Req.Test.json(conn, %{"text" => "Hola mundo"})
    end)

    assert {:ok, "Hola mundo"} = ASR.transcribe(<<1, 2, 3>>, "test.mp3")
  end

  test "transcribe/2 returns not configured when inference is disabled" do
    Application.delete_env(:dran, :inference)

    assert {:error, :not_configured} = ASR.transcribe(<<1, 2, 3>>, "test.mp3")
  end

  defp ensure_queue_started(capability) do
    case Registry.start_link(keys: :unique, name: Dran.Inference.QueueRegistry) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    case Queue.start_link(capability: capability) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end
end
