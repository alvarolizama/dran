defmodule Dran.Agent.Ingest.UtilsTest do
  # Unit tests for Dran.Agent.Ingest.Utils extraction logic.
  #
  # Two layers are exercised:
  #   1. extraction_strategy/1 — a pure function over content_type, no
  #      network or DB access required.
  #   2. build_file_body fallback — when inference is disabled, ingest_file
  #      must degrade to the original download-link body. This is verified
  #      through ingest_file/6 itself with a sandboxed DB.
  #
  # The HTTP-mocking pattern (req_plug + Req.Test.stub) mirrors
  # test/dran/ingest/converter_test.exs and test/dran/inference/*_test.exs.
  use Dran.DataCase, async: false

  alias Dran.Agent.Ingest.Utils
  alias Dran.{Brain, Uploads}

  # ------------------------------------------------------------------
  # Pure strategy tests — no inference config, no DB, no network.
  # ------------------------------------------------------------------

  describe "extraction_strategy/1" do
    test "returns :markitdown for supported document MIME types" do
      for mime <- Dran.Inference.MarkItDown.supported_mime_types() do
        assert Utils.extraction_strategy(mime) == :markitdown,
               "expected :markitdown for #{inspect(mime)}"
      end
    end

    test "returns :vision for image MIME types" do
      for mime <- ~w(image/png image/jpeg image/gif image/webp image/svg+xml) do
        assert Utils.extraction_strategy(mime) == :vision,
               "expected :vision for #{inspect(mime)}"
      end
    end

    test "returns :asr for audio MIME types" do
      for mime <- ~w(audio/mpeg audio/mp3 audio/wav audio/x-wav audio/ogg audio/aac) do
        assert Utils.extraction_strategy(mime) == :asr,
               "expected :asr for #{inspect(mime)}"
      end
    end

    test "returns :none for unsupported MIME types" do
      for mime <- ~w(application/octet-stream application/x-msdownload video/mp4 text/html) do
        assert Utils.extraction_strategy(mime) == :none,
               "expected :none for #{inspect(mime)}"
      end
    end

    test "prioritizes markitdown over prefix matching" do
      # text/plain is in MarkItDown.supported_mime_types, not matched by
      # the image/audio prefix branches — confirms ordering precedence.
      assert Utils.extraction_strategy("text/plain") == :markitdown
    end
  end

  # ------------------------------------------------------------------
  # Fallback tests — inference disabled, no stubs needed.
  # ------------------------------------------------------------------

  describe "ingest_file/6 fallback when inference disabled" do
    setup do
      original = Application.get_env(:dran, :inference)

      # Inference explicitly off: base_url nil => Config.enabled?() is false.
      Application.put_env(:dran, :inference,
        base_url: nil,
        api_key: nil,
        timeout: 100
      )

      on_exit(fn ->
        if is_nil(original) do
          Application.delete_env(:dran, :inference)
        else
          Application.put_env(:dran, :inference, original)
        end
      end)

      context =
        Brain.get_context_by_slug("personal") ||
          elem(Brain.create_context(%{name: "Personal", slug: "personal"}), 1)

      {:ok, context: context}
    end

    test "PDF falls back to download link body", %{context: ctx} do
      {:ok, page} =
        Utils.ingest_file(
          ctx,
          "https://example.com/doc.pdf",
          "fake pdf bytes",
          "doc.pdf",
          "application/pdf",
          %{}
        )

      assert page.body =~ "[Download]"
      assert page.body =~ "Source: https://example.com/doc.pdf"
      refute page.body =~ "**Description:**"
      refute page.body =~ "**Transcription:**"
    end

    test "image falls back to download link body", %{context: ctx} do
      png = <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, "IHDR">>

      {:ok, page} =
        Utils.ingest_file(
          ctx,
          "https://example.com/screenshot.png",
          png,
          "screenshot.png",
          "image/png",
          %{}
        )

      assert page.body =~ "[Download]"
      assert page.body =~ "Source: https://example.com/screenshot.png"
      refute page.body =~ "**Description:**"
    end

    test "audio falls back to download link body", %{context: ctx} do
      {:ok, page} =
        Utils.ingest_file(
          ctx,
          "https://example.com/podcast.mp3",
          <<1, 2, 3, 4>>,
          "podcast.mp3",
          "audio/mpeg",
          %{}
        )

      assert page.body =~ "[Download]"
      assert page.body =~ "Source: https://example.com/podcast.mp3"
      refute page.body =~ "**Transcription:**"
    end

    test "unsupported file type falls back to download link body", %{context: ctx} do
      {:ok, page} =
        Utils.ingest_file(
          ctx,
          "https://example.com/blob.bin",
          <<0, 1, 2>>,
          "blob.bin",
          "application/octet-stream",
          %{}
        )

      assert page.body =~ "[Download]"
    end

    test "page metadata is preserved regardless of extraction state", %{context: ctx} do
      {:ok, page} =
        Utils.ingest_file(
          ctx,
          "https://example.com/doc.pdf",
          "fake pdf bytes",
          "doc.pdf",
          "application/pdf",
          %{"tags" => ["research"], "owner" => "alice"}
        )

      assert page.meta["kind"] == "file"
      assert page.meta["mime_type"] == "application/pdf"
      assert page.meta["filename"] == "doc.pdf"
      assert page.meta["source_url"] == "https://example.com/doc.pdf"
      assert page.owner == "alice"
      assert page.tags == ["research"]
    end
  end

  # ------------------------------------------------------------------
  # Extraction integration tests — inference enabled with Req.Test stubs.
  # Pattern copied from test/dran/ingest/converter_test.exs.
  # ------------------------------------------------------------------

  describe "ingest_file/6 with inference enabled" do
    setup do
      original = Application.get_env(:dran, :inference)

      Application.put_env(:dran, :inference,
        base_url: "http://localhost:8000/v1",
        api_key: "test-key",
        markitdown_model: "MarkItDown",
        asr_model: "Qwen3-ASR",
        vision_model: "Qwen3.6-35B-A3B",
        timeout: 5_000,
        req_plug: {Req.Test, Dran.Inference.Client},
        # Prevent background embeddings/augmenter tasks from polluting
        # the Req.Test stub with /v1/embeddings calls during create_page.
        schedule_async: false
      )

      ensure_queue_started(:markdown)
      ensure_queue_started(:audio)
      ensure_queue_started(:vision)
      ensure_queue_started(:embed)

      on_exit(fn ->
        if is_nil(original) do
          Application.delete_env(:dran, :inference)
        else
          Application.put_env(:dran, :inference, original)
        end
      end)

      context =
        Brain.get_context_by_slug("personal") ||
          elem(Brain.create_context(%{name: "Personal", slug: "personal"}), 1)

      {:ok, context: context}
    end

    # Brain.create_page runs Embeddings.schedule synchronously when
    # schedule_async: false, so every stub must also answer /v1/embeddings.
    # PageAugmenter also calls /v1/chat/completions for summaries — answer
    # those generically and let the extraction_fn handle its own model.
    defp routing_stub(extraction_fn) do
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
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            decoded = Jason.decode!(body)

            if decoded["model"] in ["MarkItDown", "Qwen3.6-35B-A3B"] do
              extraction_fn.(conn, decoded)
            else
              Req.Test.json(conn, %{
                "choices" => [
                  %{"message" => %{"role" => "assistant", "content" => "{}"}}
                ]
              })
            end

          _ ->
            extraction_fn.(conn, nil)
        end
      end)
    end

    test "PDF is converted to markdown via MarkItDown", %{context: ctx} do
      routing_stub(fn conn, decoded ->
        assert decoded["model"] == "MarkItDown"

        Req.Test.json(conn, %{
          "choices" => [
            %{
              "message" => %{"role" => "assistant", "content" => "# Report\n\nExtracted content."}
            }
          ]
        })
      end)

      {:ok, page} =
        Utils.ingest_file(
          ctx,
          "https://example.com/report.pdf",
          "fake pdf bytes",
          "report.pdf",
          "application/pdf",
          %{}
        )

      assert page.body =~ "Source: https://example.com/report.pdf"
      assert page.body =~ "# Report"
      assert page.body =~ "Extracted content."
      # No download link when extraction succeeds.
      refute page.body =~ "[Download]"
    end

    test "image is described via Vision", %{context: ctx} do
      routing_stub(fn conn, decoded ->
        assert decoded["model"] == "Qwen3.6-35B-A3B"

        [message] = decoded["messages"]
        [text_part, image_part] = message["content"]
        assert text_part["type"] == "text"
        assert text_part["text"] =~ "Describe this image in detail, in Spanish"
        assert image_part["type"] == "image_url"

        Req.Test.json(conn, %{
          "choices" => [
            %{"message" => %{"role" => "assistant", "content" => "Un gráfico de barras azul."}}
          ]
        })
      end)

      png = <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, "IHDR">>

      {:ok, page} =
        Utils.ingest_file(
          ctx,
          "https://example.com/chart.png",
          png,
          "chart.png",
          "image/png",
          %{}
        )

      assert page.body =~ "Source: https://example.com/chart.png"
      assert page.body =~ "**Description:** Un gráfico de barras azul."
      assert page.body =~ "[View image]"
      refute page.body =~ "[Download]"
    end

    test "audio is transcribed via ASR", %{context: ctx} do
      routing_stub(fn conn, _decoded ->
        assert conn.request_path == "/v1/audio/transcriptions"
        Req.Test.json(conn, %{"text" => "Hola, esto es una prueba de audio."})
      end)

      {:ok, page} =
        Utils.ingest_file(
          ctx,
          "https://example.com/clip.mp3",
          <<1, 2, 3, 4>>,
          "clip.mp3",
          "audio/mpeg",
          %{}
        )

      assert page.body =~ "Source: https://example.com/clip.mp3"
      assert page.body =~ "**Transcription:** Hola, esto es una prueba de audio."
      assert page.body =~ "[Listen]"
      refute page.body =~ "[Download]"
    end

    test "extraction failure degrades gracefully to download link", %{context: ctx} do
      # Simulate an upstream error for the extraction call. Embeddings still
      # succeed so create_page doesn't blow up; the extraction error must be
      # swallowed and the body must fall back to the download link.
      routing_stub(fn conn, _decoded ->
        Plug.Conn.resp(conn, 500, "{}")
      end)

      {:ok, page} =
        Utils.ingest_file(
          ctx,
          "https://example.com/broken.pdf",
          "fake pdf bytes",
          "broken.pdf",
          "application/pdf",
          %{}
        )

      assert page.body =~ "[Download]"
      assert page.body =~ "Source: https://example.com/broken.pdf"
    end

    test "unsupported MIME type with inference on still falls back", %{context: ctx} do
      # No extraction call is made for unsupported types, but create_page still
      # schedules embeddings/augmentation — stub those out.
      routing_stub(fn conn, _decoded ->
        Plug.Conn.resp(conn, 500, "{}")
      end)

      {:ok, page} =
        Utils.ingest_file(
          ctx,
          "https://example.com/blob.bin",
          <<0, 1, 2>>,
          "blob.bin",
          "application/octet-stream",
          %{}
        )

      assert page.body =~ "[Download]"
    end
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
