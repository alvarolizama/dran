defmodule Dran.Ingest.ConverterTest do
  use ExUnit.Case, async: false

  alias Dran.Ingest.Converter

  setup do
    original = Application.get_env(:dran, :inference)

    Application.put_env(:dran, :inference,
      base_url: "http://localhost:8000/v1",
      api_key: "test-key",
      embedding_model: "Qwen3-Embedding",
      rerank_model: "Qwen3-Reranker",
      markitdown_model: "MarkItDown",
      chat_model: "Qwen3.6-35B-A3B",
      timeout: 5_000,
      req_plug: {Req.Test, Dran.Inference.Client},
      use_rerank: false,
      embedding_dimensions: 1024
    )

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:dran, :inference)
      else
        Application.put_env(:dran, :inference, original)
      end
    end)

    :ok
  end

  test "rejects unsupported MIME types" do
    assert {:error, message} = Converter.convert("x.exe", "application/x-msdownload", "data")
    assert message =~ "unsupported file type"
  end

  test "rejects files over the upload limit" do
    max_size = Dran.Uploads.max_size()
    too_big = String.duplicate("x", max_size + 1)

    assert {:error, message} = Converter.convert("x.pdf", "application/pdf", too_big)
    assert message =~ "file too large"
  end

  test "converts supported files and sanitizes markdown" do
    Req.Test.stub(Dran.Inference.Client, fn conn ->
      assert conn.request_path == "/v1/chat/completions"
      Req.Test.json(conn, chat_response("# Hello\n\n<script>alert(1)</script>"))
    end)

    assert {:ok, %{title: "report", body: body}} =
             Converter.convert("report.txt", "text/plain", "hello world")

    assert body =~ "# Hello"
    refute body =~ "<script>"
  end

  test "extracts a clean title from filename" do
    assert Converter.title("my-report_final.txt") == "my report final"
  end

  defp chat_response(content) do
    %{
      "id" => "chat-test",
      "object" => "chat.completion",
      "model" => "MarkItDown",
      "choices" => [
        %{
          "index" => 0,
          "message" => %{"role" => "assistant", "content" => content},
          "finish_reason" => "stop"
        }
      ],
      "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15}
    }
  end
end
