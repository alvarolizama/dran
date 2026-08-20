defmodule Dran.Brain.SemanticSearchTest do
  use Dran.DataCase, async: false

  alias Dran.Brain
  alias Dran.Page

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
      context = Brain.get_workspace_by_slug("personal")

      # Create directly so Brain.create_page does not auto-generate an embedding.
      _without =
        %Dran.Page{
          workspace_id: context.id,
          title: "Without embedding",
          slug: "without-embedding",
          body: "no vector",
          page_type: "note",
          embedding_hash: nil,
          embedding: nil
        }
        |> Dran.Repo.insert!()

      _with_vec =
        %Dran.Page{
          workspace_id: context.id,
          title: "With embedding",
          slug: "with-embedding",
          body: "has vector",
          page_type: "note",
          embedding_hash: "xyz",
          embedding: Pgvector.new(test_vector())
        }
        |> Dran.Repo.insert!()

      {:ok, results} = Brain.semantic_search("anything", workspace_id: context.id, limit: 10)

      assert length(results) == 1
      assert hd(results).slug == "with-embedding"
      assert hd(results).distance >= 0
    end

    test "returns not_configured when inference is disabled" do
      Application.put_env(:dran, :inference, nil)

      assert {:error, :not_configured} =
               Brain.semantic_search("x", workspace_id: Ecto.UUID.generate())
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
      context = Brain.get_workspace_by_slug("personal")

      page =
        %Dran.Page{
          workspace_id: context.id,
          title: "Elixir",
          slug: "elixir",
          body: "A functional language",
          page_type: "entity",
          embedding_hash: "xyz",
          embedding: Pgvector.new(test_vector())
        }
        |> Dran.Repo.insert!()

      {:ok, results} = Brain.hybrid_search("functional language", workspace_id: context.id)

      assert length(results) >= 1
      assert hd(results).slug == page.slug
    end
  end

  describe "hybrid_search/2 with pagerank boost" do
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

    test "boosts pages with higher pagerank meta to the top" do
      context = Brain.get_workspace_by_slug("personal")

      # Two pages with identical body so FTS ts_rank ties. Both get the same
      # embedding (same mocked vector) so semantic distance ties. The only
      # differentiator is meta["pagerank"].
      shared_body = "elixir deployment guide release hot code reload"

      _low =
        %Dran.Page{
          workspace_id: context.id,
          title: "Low rank",
          slug: "low-rank",
          body: shared_body,
          page_type: "note",
          embedding_hash: "xyz",
          embedding: Pgvector.new(test_vector()),
          meta: %{"pagerank" => 0.001}
        }
        |> Dran.Repo.insert!()

      _high =
        %Dran.Page{
          workspace_id: context.id,
          title: "High rank",
          slug: "high-rank",
          body: shared_body,
          page_type: "note",
          embedding_hash: "xyz",
          embedding: Pgvector.new(test_vector()),
          meta: %{"pagerank" => 0.9}
        }
        |> Dran.Repo.insert!()

      {:ok, results} = Brain.hybrid_search("elixir deployment guide", workspace_id: context.id)

      assert length(results) >= 2
      assert hd(results).slug == "high-rank"
    end

    test "pages without pagerank meta are unaffected (boost factor = 1.0)" do
      context = Brain.get_workspace_by_slug("personal")

      shared_body = "rust ownership borrow checker move semantics"

      _no_pr =
        %Dran.Page{
          workspace_id: context.id,
          title: "No pagerank",
          slug: "no-pagerank",
          body: shared_body,
          page_type: "note",
          embedding_hash: "xyz",
          embedding: Pgvector.new(test_vector()),
          meta: %{}
        }
        |> Dran.Repo.insert!()

      _with_pr =
        %Dran.Page{
          workspace_id: context.id,
          title: "With pagerank",
          slug: "with-pagerank",
          body: shared_body,
          page_type: "note",
          embedding_hash: "xyz",
          embedding: Pgvector.new(test_vector()),
          meta: %{"pagerank" => 0.5}
        }
        |> Dran.Repo.insert!()

      {:ok, results} = Brain.hybrid_search("rust ownership borrow", workspace_id: context.id)

      # The page WITH pagerank must rank strictly above the page without it,
      # because boost * 0.0 = 0 (no change) for the empty-meta page but
      # boost * 0.5 > 0 for the other.
      assert length(results) >= 2
      assert hd(results).slug == "with-pagerank"
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

      context = Brain.get_workspace_by_slug("personal")

      {:ok, page} =
        Brain.create_page(%{
          workspace_id: context.id,
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
