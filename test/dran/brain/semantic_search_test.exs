defmodule Dran.Brain.SemanticSearchTest do
  use Dran.DataCase, async: false

  alias Dran.Brain
  alias Dran.Brain.Page

  defp test_vector do
    Enum.map(1..1024, fn i -> i / 1000.0 end)
  end

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
      schedule_async: false
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

  describe "semantic_search/2" do
    setup do
      Req.Test.stub(Dran.Inference.Client, fn conn ->
        assert conn.request_path == "/v1/embeddings"

        Req.Test.json(conn, %{
          "object" => "list",
          "data" => [
            %{
              "object" => "embedding",
              "index" => 0,
              "embedding" => test_vector()
            }
          ]
        })
      end)

      :ok
    end

    test "returns only pages that have embeddings" do
      context = Brain.get_context_by_slug("personal")

      # Create directly so Brain.create_page does not auto-generate an embedding.
      _without =
        %Dran.Brain.Page{
          context_id: context.id,
          title: "Without embedding",
          slug: "without-embedding",
          body: "no vector",
          page_type: "note",
          embedding_hash: nil,
          embedding: nil
        }
        |> Dran.Repo.insert!()

      _with_vec =
        %Dran.Brain.Page{
          context_id: context.id,
          title: "With embedding",
          slug: "with-embedding",
          body: "has vector",
          page_type: "note",
          embedding_hash: "xyz",
          embedding: Pgvector.new(test_vector())
        }
        |> Dran.Repo.insert!()

      {:ok, results} = Brain.semantic_search("anything", context_id: context.id, limit: 10)

      assert length(results) == 1
      assert hd(results).slug == "with-embedding"
      assert hd(results).distance >= 0
    end

    test "returns not_configured when inference is disabled" do
      Application.put_env(:dran, :inference, nil)

      assert {:error, :not_configured} =
               Brain.semantic_search("x", context_id: Ecto.UUID.generate())
    end
  end

  describe "hybrid_search/2" do
    setup do
      Req.Test.stub(Dran.Inference.Client, fn conn ->
        assert conn.request_path == "/v1/embeddings"

        Req.Test.json(conn, %{
          "object" => "list",
          "data" => [
            %{
              "object" => "embedding",
              "index" => 0,
              "embedding" => test_vector()
            }
          ]
        })
      end)

      :ok
    end

    test "merges fts and semantic results" do
      context = Brain.get_context_by_slug("personal")

      page =
        %Dran.Brain.Page{
          context_id: context.id,
          title: "Elixir",
          slug: "elixir",
          body: "A functional language",
          page_type: "entity",
          embedding_hash: "xyz",
          embedding: Pgvector.new(test_vector())
        }
        |> Dran.Repo.insert!()

      {:ok, results} = Brain.hybrid_search("functional language", context_id: context.id)

      assert length(results) >= 1
      assert hd(results).slug == page.slug
    end
  end

  describe "page creation triggers embedding generation" do
    test "creates a page and stores its embedding synchronously" do
      Req.Test.stub(Dran.Inference.Client, fn conn ->
        Req.Test.json(conn, %{
          "object" => "list",
          "data" => [
            %{
              "object" => "embedding",
              "index" => 0,
              "embedding" => List.duplicate(0.1, 1024)
            }
          ]
        })
      end)

      context = Brain.get_context_by_slug("personal")

      {:ok, page} =
        Brain.create_page(%{
          context_id: context.id,
          title: "Auto embedded",
          slug: "auto-embedded",
          body: "Some content",
          page_type: "note"
        })

      refreshed = Dran.Repo.get!(Page, page.id)
      assert refreshed.embedding_hash != nil
      assert refreshed.embedding != nil
    end
  end
end
