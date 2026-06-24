defmodule Dran.Brain.PageAugmenterTest do
  use Dran.DataCase, async: false

  alias Dran.Brain
  alias Dran.Brain.Page
  alias Dran.Brain.PageAugmenter

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

  test "run/1 skips when inference is not configured" do
    Application.put_env(:dran, :inference, nil)

    context = Brain.get_context_by_slug("personal")

    {:ok, page} =
      Brain.create_page(%{
        context_id: context.id,
        title: "Standalone note",
        slug: "standalone-note",
        body: "No inference available.",
        page_type: "note"
      })

    assert :ok = PageAugmenter.run(page)

    assert %{
             outbound: [],
             inbound: []
           } = Brain.list_relations_for_page(page.id)
  end

  test "run/1 enriches summary and creates high-confidence auto-relations" do
    Application.put_env(:dran, :inference, nil)

    context = Brain.get_context_by_slug("personal")

    {:ok, target} =
      Brain.create_page(%{
        context_id: context.id,
        title: "Phoenix framework",
        slug: "phoenix-framework",
        body: "Phoenix is a web framework for Elixir.",
        page_type: "note"
      })

    target
    |> Ecto.Changeset.change(
      embedding: Pgvector.new(List.duplicate(0.0, 1024)),
      embedding_hash: "hash"
    )
    |> Dran.Repo.update!()

    {:ok, page} =
      Brain.create_page(%{
        context_id: context.id,
        title: "My Phoenix project",
        slug: "my-phoenix-project",
        body: "I am building a web app with Phoenix.",
        page_type: "note"
      })

    Application.put_env(:dran, :inference,
      base_url: "http://localhost:8000/v1",
      api_key: "test-key",
      embedding_model: "Qwen3-Embedding",
      rerank_model: "Qwen3-Reranker",
      markitdown_model: "MarkItDown",
      chat_model: "Qwen3.6-35B-A3B",
      timeout: 5_000,
      req_plug: {Req.Test, Dran.Inference.Client},
      schedule_async: false,
      use_rerank: false,
      embedding_dimensions: 1024
    )

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
          Req.Test.json(conn, %{
            "id" => "chat-test",
            "object" => "chat.completion",
            "model" => "Qwen3.6-35B-A3B",
            "choices" => [
              %{
                "index" => 0,
                "message" => %{
                  "role" => "assistant",
                  "content" =>
                    ~s({"summary": "Building a Phoenix web app", "tags": ["phoenix"], "entities": [], "links": ["phoenix-framework"]})
                },
                "finish_reason" => "stop"
              }
            ]
          })
      end
    end)

    assert :ok = PageAugmenter.run(page)

    refreshed = Dran.Repo.get!(Page, page.id)
    assert refreshed.summary == "Building a Phoenix web app"
    assert "phoenix" in refreshed.tags

    %{outbound: outbound} = Brain.list_relations_for_page(page.id)
    assert Enum.any?(outbound, &(&1.target_id == target.id and &1.relation_type == "related"))
  end
end
