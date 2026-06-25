defmodule Dran.Inference.VisionTest do
  use ExUnit.Case, async: false

  alias Dran.Inference.Vision

  setup do
    original = Application.get_env(:dran, :inference)

    Application.put_env(:dran, :inference,
      base_url: "http://localhost:8000/v1",
      api_key: "test-key",
      vision_model: "Qwen3.6-35B-A3B",
      timeout: 5_000,
      req_plug: {Req.Test, Dran.Inference.Client}
    )

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

  test "describe/2 returns the image description" do
    Req.Test.stub(Dran.Inference.Client, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/chat/completions"

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)
      assert decoded["model"] == "Qwen3.6-35B-A3B"

      [message] = decoded["messages"]
      assert length(message["content"]) == 2

      Req.Test.json(conn, %{
        "choices" => [%{"message" => %{"role" => "assistant", "content" => "A red cat"}}]
      })
    end)

    assert {:ok, "A red cat"} = Vision.describe(<<0xFF, 0xD8, 0xFF>>, "What is in this image?")
  end

  test "describe/2 returns not configured when inference is disabled" do
    Application.delete_env(:dran, :inference)

    assert {:error, :not_configured} = Vision.describe(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>>)
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
