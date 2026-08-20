defmodule DranWeb.API.SearchControllerTest do
  use DranWeb.ConnCase, async: false

  alias Dran.Knowledge

  setup %{conn: conn} do
    original = Application.get_env(:dran, :inference)

    Application.put_env(:dran, :inference,
      base_url: "http://localhost:8000/v1",
      api_key: "test-key",
      embedding_model: "Qwen3-Embedding",
      rerank_model: "Qwen3-Reranker",
      timeout: 5_000,
      req_plug: {Req.Test, Dran.Inference.Client},
      schedule_async: false,
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

  describe "GET /api/search/semantic" do
    test "returns semantic search results", %{conn: conn} do
      Req.Test.stub(Dran.Inference.Client, fn conn ->
        Req.Test.json(conn, %{
          "object" => "list",
          "data" => [
            %{"object" => "embedding", "index" => 0, "embedding" => List.duplicate(0.0, 1024)}
          ]
        })
      end)

      # Fresh context: the shared "personal" context can carry pages with
      # embeddings from other tests in the shared sandbox transaction. The
      # stubbed zero-vector query embedding sorts as NaN in pgvector cosine
      # distance (NaN sorts last in Postgres), so any residue could push the
      # test's page past the result limit.
      uniq = System.unique_integer([:positive])

      {:ok, context} =
        Knowledge.create_workspace(%{name: "Semantic #{uniq}", slug: "semantic-#{uniq}"})

      {:ok, page} =
        Knowledge.create_page(%{
          workspace_id: context.id,
          title: "Semantic hit",
          slug: "semantic-hit",
          body: "Body",
          page_type: "note",
          embedding: Pgvector.new(List.duplicate(0.0, 1024)),
          embedding_hash: "hash"
        })

      conn =
        get(conn, ~p"/api/search/semantic", %{
          "q" => "test query",
          "workspace" => context.slug
        })

      assert json_response(conn, 200)
      %{"data" => data} = json_response(conn, 200)

      assert length(data) == 1
      assert hd(data)["slug"] == page.slug
    end

    test "returns 503 when inference is not configured", %{conn: conn} do
      Application.put_env(:dran, :inference, nil)

      conn =
        get(conn, ~p"/api/search/semantic", %{
          "q" => "test",
          "workspace" => "personal"
        })

      assert json_response(conn, 503)

      assert %{"errors" => %{"detail" => "Inference API is not configured"}} =
               json_response(conn, 503)
    end
  end
end
