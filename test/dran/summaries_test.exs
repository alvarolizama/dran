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
      markitdown_model: "MarkItDown",
      chat_model: "Qwen3.6-35B-A3B",
      timeout: 5_000,
      req_plug: {Req.Test, Dran.Inference.Client},
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
      context_id: Ecto.UUID.generate(),
      title: title,
      slug: title |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-"),
      body: body,
      page_type: "note",
      tags: [],
      meta: %{}
    }
  end

  defp chat_response(content) do
    %{
      "id" => "chat-test",
      "object" => "chat.completion",
      "model" => "Qwen3.6-35B-A3B",
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
