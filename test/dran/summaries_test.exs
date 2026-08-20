defmodule Dran.SummariesTest do
  use Dran.DataCase, async: false

  alias Dran.Brain.Page
  alias Dran.Summaries

  setup do
    original = Application.get_env(:dran, :inference)

    Application.put_env(:dran, :inference,
      base_url: "http://localhost:8000/v1",
      api_key: "test-key",
      embedding_model: "Qwen3-Embedding",
      rerank_model: "Qwen3-Reranker",
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

    :ok
  end

  test "summarize_page extracts JSON summary" do
    Req.Test.stub(Dran.Inference.Client, fn conn ->
      assert conn.request_path == "/v1/chat/completions"
      Req.Test.json(conn, chat_response(~s({"summary": "A note about Elixir"})))
    end)

    page = build_page("Elixir is a functional language", "Elixir note")
    assert {:ok, "A note about Elixir"} = Summaries.summarize_page(page)
  end

  test "suggest_tags extracts and slugs tags" do
    Req.Test.stub(Dran.Inference.Client, fn conn ->
      Req.Test.json(conn, chat_response(~s({"tags": ["Elixir", "Functional Programming"]})))
    end)

    page = build_page("Elixir is a functional language", "Elixir note")
    assert {:ok, ["elixir", "functional-programming"]} = Summaries.suggest_tags(page)
  end

  test "returns not_configured when inference is disabled" do
    Application.put_env(:dran, :inference, nil)
    page = build_page("x", "y")

    assert {:error, :not_configured} = Summaries.summarize_page(page)
    assert {:error, :not_configured} = Summaries.suggest_tags(page)
  end

  defp build_page(title, body) do
    %Page{
      id: Ecto.UUID.generate(),
      workspace_id: Ecto.UUID.generate(),
      title: title,
      slug: title |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-"),
      body: body,
      page_type: "note",
      tags: [],
      meta: %{}
    }
  end

  describe "candidate_pages/1" do
    test "returns semantically closest pages, not just most recent" do
      context = Dran.Brain.get_workspace_by_slug("personal")

      # The target page has an embedding close to "relevant" pages below.
      # We use synthetic 1024-dim vectors: target = [1.0, 0.0, ...],
      # relevant pages = [0.9, 0.0, ...] (small distance),
      # noise pages = [0.0, 1.0, 0.0, ...] (max distance).
      target_vec = [1.0 | List.duplicate(0.0, 1023)]
      relevant_vec = [0.9 | List.duplicate(0.0, 1023)]
      noise_vec = [0.0, 1.0 | List.duplicate(0.0, 1022)]

      # Insert 51 noise pages, each with updated_at newer than the relevant
      # ones, so a recency-based selection would pick all noise pages.
      old_ts = ~U[2020-01-01 00:00:00Z]
      new_ts = ~U[2026-01-01 00:00:00Z]

      for i <- 1..51 do
        %Page{
          workspace_id: context.id,
          title: "Noise #{i}",
          slug: "noise-#{i}",
          body: "noise body",
          page_type: "note",
          embedding_hash: "noise-#{i}",
          embedding: Pgvector.new(noise_vec),
          updated_at: new_ts,
          inserted_at: new_ts
        }
        |> Dran.Repo.insert!()
      end

      # 3 semantically relevant pages, but with OLD updated_at so a
      # recency-sorted list_pages(limit: 50) would NOT include them.
      relevant_slugs =
        for i <- 1..3 do
          %Page{
            workspace_id: context.id,
            title: "Relevant #{i}",
            slug: "relevant-#{i}",
            body: "relevant body",
            page_type: "note",
            embedding_hash: "relevant-#{i}",
            embedding: Pgvector.new(relevant_vec),
            updated_at: old_ts,
            inserted_at: old_ts
          }
          |> Dran.Repo.insert!()
          |> Map.fetch!(:slug)
        end

      target =
        %Page{
          workspace_id: context.id,
          title: "Target",
          slug: "target",
          body: "target body",
          page_type: "note",
          embedding_hash: "target",
          embedding: Pgvector.new(target_vec)
        }
        |> Dran.Repo.insert!()

      candidates = Summaries.candidate_pages(target)

      # All 3 relevant pages must appear even though they are the oldest.
      candidate_slugs = Enum.map(candidates, & &1.slug)

      for slug <- relevant_slugs do
        assert slug in candidate_slugs,
               "expected semantically close page #{slug} in candidates, got: #{inspect(candidate_slugs)}"
      end
    end

    test "falls back to list_pages when page has no embedding" do
      context = Dran.Brain.get_workspace_by_slug("personal")

      for i <- 1..3 do
        %Page{
          workspace_id: context.id,
          title: "Page #{i}",
          slug: "page-#{i}",
          body: "body",
          page_type: "note",
          embedding_hash: nil,
          embedding: nil
        }
        |> Dran.Repo.insert!()
      end

      target =
        %Page{
          workspace_id: context.id,
          title: "Target no vec",
          slug: "target-no-vec",
          body: "body",
          page_type: "note",
          embedding_hash: nil,
          embedding: nil
        }
        |> Dran.Repo.insert!()

      candidates = Summaries.candidate_pages(target)
      slugs = Enum.map(candidates, & &1.slug)

      assert "page-1" in slugs
      assert "page-2" in slugs
      assert "page-3" in slugs
      refute "target-no-vec" in slugs
    end
  end

  defp chat_response(content) do
    %{
      "id" => "chat-test",
      "object" => "chat.completion",
      "model" => "Qwen3.5-9B",
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
