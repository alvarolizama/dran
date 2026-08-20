defmodule Dran.EmbeddingsTest do
  use Dran.DataCase, async: false

  alias Dran.Brain
  alias Dran.Brain.Page
  alias Dran.Embeddings

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

  describe "text_for_page/1" do
    test "concatenates title, summary, body and tags" do
      page = %Page{
        title: "Elixir",
        summary: "Functional language",
        body: "Runs on BEAM",
        tags: ["programming", "elixir"]
      }

      text = Embeddings.text_for_page(page)

      assert text =~ "Elixir"
      assert text =~ "Functional language"
      assert text =~ "Runs on BEAM"
      assert text =~ "programming elixir"
      refute text =~ "slug"
    end
  end

  describe "generate/1" do
    test "computes and stores a vector embedding" do
      Req.Test.stub(Dran.Inference.Client, fn conn ->
        assert conn.request_path == "/v1/embeddings"
        Req.Test.json(conn, embeddings_response(5))
      end)

      context = Brain.get_workspace_by_slug("personal")

      page =
        Dran.Brain.Page.create_changeset(%{
          workspace_id: context.id,
          title: "Elixir",
          slug: "elixir",
          body: "Functional language",
          page_type: "entity"
        })
        |> Dran.Repo.insert!()

      assert {:ok, page} = Embeddings.generate(page)
      assert page.embedding_hash != nil
      assert page.embedding != nil

      refreshed = Dran.Repo.get!(Page, page.id)
      assert refreshed.embedding_hash == Embeddings.hash_text(Embeddings.text_for_page(page))
      assert Pgvector.to_list(refreshed.embedding) |> length() == 1024
    end
  end

  describe "needs_embedding?/1" do
    test "true when embedding_hash is nil" do
      page = %Page{embedding_hash: nil}
      assert Embeddings.needs_embedding?(page)
    end

    test "false when hash matches current text" do
      page = %Page{
        title: "Elixir",
        summary: nil,
        body: "",
        tags: [],
        embedding_hash: Embeddings.hash_text("Elixir")
      }

      refute Embeddings.needs_embedding?(page)
    end

    test "true when content changed" do
      page = %Page{
        title: "Elixir",
        summary: nil,
        body: "",
        tags: [],
        embedding_hash: "old-hash"
      }

      assert Embeddings.needs_embedding?(page)
    end
  end

  describe "backfill_pages/1" do
    test "generates embeddings for all pages without one" do
      Req.Test.stub(Dran.Inference.Client, fn conn ->
        Req.Test.json(conn, embeddings_response(1))
      end)

      # Fresh context: the exact `count == 2` below must not see pages from
      # the shared "personal" context (it can carry stale rows committed
      # outside the sandbox).
      uniq = System.unique_integer([:positive])

      {:ok, context} =
        Brain.create_workspace(%{name: "Backfill #{uniq}", slug: "backfill-#{uniq}"})

      p1 =
        Dran.Brain.Page.create_changeset(%{
          workspace_id: context.id,
          title: "Page One",
          slug: "page-one",
          body: "body one",
          page_type: "note",
          embedding_hash: "matching-" <> Embeddings.hash_text("Page One\n\nbody one"),
          embedding: nil
        })
        |> Dran.Repo.insert!()

      p2 =
        Dran.Brain.Page.create_changeset(%{
          workspace_id: context.id,
          title: "Page Two",
          slug: "page-two",
          body: "body two",
          page_type: "note",
          embedding_hash: "matching-" <> Embeddings.hash_text("Page Two\n\nbody two"),
          embedding: nil
        })
        |> Dran.Repo.insert!()

      {count, failures} = Embeddings.backfill_pages(context, async: false)

      assert count == 2
      assert failures == []

      for p <- [p1, p2], do: assert(Dran.Repo.get!(Page, p.id).embedding != nil)
    end
  end

  defp embeddings_response(dim) do
    vec = List.duplicate(0.0, 1024) |> List.replace_at(0, dim / 10.0)

    %{
      "object" => "list",
      "data" => [
        %{
          "object" => "embedding",
          "index" => 0,
          "embedding" => vec
        }
      ],
      "model" => "Qwen3-Embedding",
      "usage" => %{
        "prompt_tokens" => 2,
        "total_tokens" => 2
      }
    }
  end
end
