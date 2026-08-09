defmodule Dran.InferenceTest do
  use ExUnit.Case, async: false

  alias Dran.Inference
  alias Dran.Inference.Config

  setup do
    original = Application.get_env(:dran, :inference)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:dran, :inference)
      else
        Application.put_env(:dran, :inference, original)
      end
    end)

    :ok
  end

  describe "when not configured" do
    setup do
      Application.put_env(:dran, :inference, nil)
      :ok
    end

    test "enabled?/0 returns false" do
      refute Inference.enabled?()
    end

    test "models/0 returns {:error, :not_configured}" do
      assert {:error, :not_configured} = Inference.models()
    end

    test "embed/1 returns {:error, :not_configured}" do
      assert {:error, :not_configured} = Inference.embed("hola")
    end

    test "rerank/2 returns {:error, :not_configured}" do
      assert {:error, :not_configured} = Inference.rerank("query", ["doc"])
    end
  end

  describe "embed/1" do
    setup do
      Req.Test.stub(Dran.Inference.Client, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v1/embeddings"

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["model"] == "Qwen3-Embedding"
        assert decoded["input"] == ["hola mundo"]

        Req.Test.json(conn, %{
          "object" => "list",
          "data" => [
            %{
              "object" => "embedding",
              "index" => 0,
              "embedding" => [0.1, 0.2, 0.3]
            }
          ],
          "model" => "Qwen3-Embedding",
          "usage" => %{
            "prompt_tokens" => 2,
            "total_tokens" => 2
          }
        })
      end)

      Application.put_env(:dran, :inference,
        base_url: "http://localhost:8000/v1",
        api_key: "test-key",
        embedding_model: "Qwen3-Embedding",
        rerank_model: "Qwen3-Reranker",
        timeout: 5_000,
        req_plug: {Req.Test, Dran.Inference.Client},
        schedule_async: false
      )

      :ok
    end

    test "returns the first embedding vector" do
      assert {:ok, [0.1, 0.2, 0.3]} = Inference.embed("hola mundo")
    end
  end

  describe "rerank/2" do
    setup do
      Req.Test.stub(Dran.Inference.Client, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v1/rerank"

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["model"] == "Qwen3-Reranker"
        assert decoded["query"] == "elixir"
        assert decoded["documents"] == ["doc1", "doc2"]

        Req.Test.json(conn, %{
          "results" => [
            %{"index" => 1, "relevance_score" => 0.9},
            %{"index" => 0, "relevance_score" => 0.4}
          ]
        })
      end)

      Application.put_env(:dran, :inference,
        base_url: "http://localhost:8000/v1",
        api_key: "test-key",
        embedding_model: "Qwen3-Embedding",
        rerank_model: "Qwen3-Reranker",
        timeout: 5_000,
        req_plug: {Req.Test, Dran.Inference.Client},
        schedule_async: false
      )

      :ok
    end

    test "returns reranked results" do
      assert {:ok, results} = Inference.rerank("elixir", ["doc1", "doc2"])

      assert results == [
               %{"index" => 1, "relevance_score" => 0.9},
               %{"index" => 0, "relevance_score" => 0.4}
             ]
    end
  end

  describe "models/0" do
    setup do
      Req.Test.stub(Dran.Inference.Client, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/v1/models"

        Req.Test.json(conn, %{
          "object" => "list",
          "data" => [
            %{"id" => "Qwen3-Embedding"},
            %{"id" => "Qwen3-Reranker"},
            %{"id" => "MarkItDown"}
          ]
        })
      end)

      Application.put_env(:dran, :inference,
        base_url: "http://localhost:8000/v1",
        api_key: "test-key",
        embedding_model: "Qwen3-Embedding",
        rerank_model: "Qwen3-Reranker",
        timeout: 5_000,
        req_plug: {Req.Test, Dran.Inference.Client},
        schedule_async: false
      )

      :ok
    end

    test "returns configured model ids" do
      assert {:ok, models} = Inference.models()
      assert Enum.map(models, & &1["id"]) == ["Qwen3-Embedding", "Qwen3-Reranker", "MarkItDown"]
    end
  end

  describe "health_check/0" do
    setup do
      Req.Test.stub(Dran.Inference.Client, fn conn ->
        Req.Test.json(conn, %{
          "object" => "list",
          "data" => [
            %{"id" => "Qwen3-Embedding"},
            %{"id" => "Qwen3-Reranker"}
          ]
        })
      end)

      Application.put_env(:dran, :inference,
        base_url: "http://localhost:8000/v1",
        api_key: "test-key",
        embedding_model: "Qwen3-Embedding",
        rerank_model: "Qwen3-Reranker",
        timeout: 5_000,
        req_plug: {Req.Test, Dran.Inference.Client},
        schedule_async: false
      )

      :ok
    end

    test "reports missing models correctly" do
      assert {:ok, {present, _missing}} = Inference.health_check()

      assert "Qwen3-Embedding" in present
      assert "Qwen3-Reranker" in present
    end
  end

  describe "Dran.Inference.Config" do
    test "load_from_env/0 returns nil when URL is unset" do
      with_env(%{"DRAN_INFERENCE_API_URL" => nil}, fn ->
        assert Config.load_from_env() == nil
      end)
    end

    test "load_from_env/0 strips trailing slash and uses env vars" do
      with_env(
        %{
          "DRAN_INFERENCE_API_URL" => "http://inference.example.com:8000/v1/",
          "DRAN_INFERENCE_API_KEY" => "secret",
          "DRAN_INFERENCE_EMBEDDING_MODEL" => "custom-embed",
          "DRAN_INFERENCE_TIMEOUT" => "15000"
        },
        fn ->
          cfg = Config.load_from_env()

          assert Keyword.get(cfg, :base_url) == "http://inference.example.com:8000/v1"
          assert Keyword.get(cfg, :api_key) == "secret"
          assert Keyword.get(cfg, :embedding_model) == "custom-embed"
          # No DRAN_INFERENCE_RERANK_MODEL set → nil (no hardcoded default)
          assert Keyword.get(cfg, :rerank_model) == nil
          assert Keyword.get(cfg, :timeout) == 15_000
        end
      )
    end
  end

  defp with_env(overrides, fun) do
    original =
      Map.new(overrides, fn {k, _} ->
        {k, System.get_env(k)}
      end)

    try do
      Enum.each(overrides, fn {k, v} ->
        if is_nil(v) do
          System.delete_env(k)
        else
          System.put_env(k, v)
        end
      end)

      fun.()
    after
      Enum.each(original, fn {k, v} ->
        if is_nil(v) do
          System.delete_env(k)
        else
          System.put_env(k, v)
        end
      end)
    end
  end
end
