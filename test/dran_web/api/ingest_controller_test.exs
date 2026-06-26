defmodule DranWeb.API.IngestControllerTest do
  use DranWeb.ConnCase, async: false

  alias Dran.Brain

  setup %{conn: conn} do
    original = Application.get_env(:dran, :inference)

    Application.put_env(:dran, :inference,
      base_url: "http://localhost:8000/v1",
      api_key: "test-key",
      embedding_model: "Qwen3-Embedding",
      rerank_model: "Qwen3-Reranker",
      markitdown_model: "MarkItDown",
      chat_model: "Qwen3.5-9B",
      timeout: 5_000,
      req_plug: {Req.Test, Dran.Inference.Client},
      schedule_async: false,
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

    {:ok, conn: put_req_header(conn, "authorization", "Bearer dran-token")}
  end

  test "POST /api/ingest/file converts a supported file and creates a note", %{conn: conn} do
    Req.Test.stub(Dran.Inference.Client, fn conn ->
      case conn.request_path do
        "/v1/embeddings" ->
          Req.Test.json(conn, %{
            "object" => "list",
            "data" => [
              %{"object" => "embedding", "index" => 0, "embedding" => List.duplicate(0.0, 1024)}
            ]
          })

        "/v1/chat/completions" ->
          Req.Test.json(conn, chat_response("# Report\n\nThis is the markdown body."))
      end
    end)

    upload = %Plug.Upload{
      content_type: "text/plain",
      filename: "report.txt",
      path: Path.join(System.tmp_dir!(), "report-#{Enum.random(1..999_999)}.txt")
    }

    File.write!(upload.path, "original text")

    conn =
      conn
      |> put_req_header("content-type", "multipart/form-data")
      |> post(~p"/api/ingest/file", %{"context" => "personal", "file" => upload})

    assert json_response(conn, 201)
    %{"data" => data} = json_response(conn, 201)
    assert data["page_type"] == "note"
    assert data["title"] == "report"

    page = Brain.get_page_by_slug("report", hd(Brain.list_pages()).context_id)
    assert page.body =~ "markdown body"
  end

  test "POST /api/ingest/file rejects unsupported file types", %{conn: conn} do
    upload = %Plug.Upload{
      content_type: "application/x-msdownload",
      filename: "malware.exe",
      path: Path.join(System.tmp_dir!(), "malware.txt")
    }

    File.write!(upload.path, "binary")

    conn = post(conn, ~p"/api/ingest/file", %{"context" => "personal", "file" => upload})

    assert json_response(conn, 422)
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
