defmodule Dran.Inference.MarkItDownTest do
  use ExUnit.Case, async: true

  alias Dran.Inference.MarkItDown

  setup do
    original = Application.get_env(:dran, :inference)

    Application.put_env(:dran, :inference,
      base_url: "http://localhost:8000/v1",
      api_key: "test-key",
      embedding_model: "Qwen3-Embedding",
      rerank_model: "Qwen3-Reranker",
      markitdown_model: "MarkItDown",
      timeout: 5_000,
      req_plug: {Req.Test, Dran.Inference.Client}
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

  describe "to_markdown/3" do
    test "rejects unsupported mime types" do
      assert {:error, :unsupported_mime_type} =
               MarkItDown.to_markdown("x.exe", "application/x-msdownload", <<1, 2, 3>>)
    end

    test "converts a PDF file to markdown" do
      Req.Test.stub(Dran.Inference.Client, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v1/chat/completions"

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["model"] == "MarkItDown"
        [message] = decoded["messages"]
        [text_part, file_part] = message["content"]
        assert text_part["type"] == "text"
        assert file_part["type"] == "file"
        assert file_part["file"]["filename"] == "notes.pdf"
        assert file_part["file"]["content_type"] == "application/pdf"
        assert Base.decode64!(file_part["file"]["file_data"]) == "fake pdf bytes"

        Req.Test.json(conn, %{
          "choices" => [
            %{
              "message" => %{
                "role" => "assistant",
                "content" => "# Notes\n\nConverted."
              }
            }
          ]
        })
      end)

      assert {:ok, "# Notes\n\nConverted."} =
               MarkItDown.to_markdown("notes.pdf", "application/pdf", "fake pdf bytes")
    end
  end

  describe "supported_mime_types/0" do
    test "includes PDF, Word, PowerPoint and plain text" do
      types = MarkItDown.supported_mime_types()

      assert "application/pdf" in types
      assert "application/vnd.openxmlformats-officedocument.wordprocessingml.document" in types
      assert "application/vnd.openxmlformats-officedocument.presentationml.presentation" in types
      assert "text/plain" in types
    end
  end
end
