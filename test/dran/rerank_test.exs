defmodule Dran.RerankTest do
  use ExUnit.Case, async: false

  alias Dran.Rerank

  setup do
    original = Application.get_env(:dran, :inference)

    Application.put_env(:dran, :inference,
      base_url: "http://localhost:8000/v1",
      api_key: "test-key",
      embedding_model: "Qwen3-Embedding",
      rerank_model: "Qwen3-Reranker",
      markitdown_model: "MarkItDown",
      timeout: 5_000,
      req_plug: {Req.Test, Dran.Inference.Client},
      use_rerank: true
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

  describe "rerank/2" do
    test "returns original order when reranking is disabled" do
      Application.put_env(
        :dran,
        :inference,
        [use_rerank: false] ++ Application.get_env(:dran, :inference)
      )

      candidates = [
        %{id: 1, title: "Elixir", excerpt: "functional"},
        %{id: 2, title: "Phoenix", excerpt: "web framework"}
      ]

      assert {:ok, ^candidates} = Rerank.rerank("elixir", candidates)
    end

    test "reorders candidates by relevance score" do
      Req.Test.stub(Dran.Inference.Client, fn conn ->
        Req.Test.json(conn, %{
          "results" => [
            %{"index" => 1, "relevance_score" => 0.9},
            %{"index" => 0, "relevance_score" => 0.1}
          ]
        })
      end)

      candidates = [
        %{id: 1, title: "Phoenix"},
        %{id: 2, title: "Elixir"}
      ]

      {:ok, [first, second]} = Rerank.rerank("elixir", candidates)

      assert first.id == 2
      assert second.id == 1
    end

    test "falls back to original order on rerank failure" do
      Req.Test.stub(Dran.Inference.Client, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      candidates = [%{id: 1, title: "A"}, %{id: 2, title: "B"}]

      assert {:ok, ^candidates} = Rerank.rerank("x", candidates)
    end

    test "handles {page, excerpt} tuples" do
      Req.Test.stub(Dran.Inference.Client, fn conn ->
        Req.Test.json(conn, %{
          "results" => [
            %{"index" => 0, "relevance_score" => 0.75}
          ]
        })
      end)

      page = %Dran.Brain.Page{title: "Elixir", body: "functional language"}
      candidates = [{page, "excerpt"}]

      assert {:ok, ^candidates} = Rerank.rerank("elixir", candidates)
    end
  end
end
