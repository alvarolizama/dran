defmodule DranWeb.API.MemoryControllerTest do
  use DranWeb.ConnCase, async: false

  alias Dran.{Accounts, Knowledge, Memory}

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

    unique = System.unique_integer([:positive])

    {:ok, owner} =
      Accounts.create_user(%{
        email: "owner-#{unique}@example.com",
        name: "Owner",
        is_owner: true
      })

    {:ok, workspace} =
      Knowledge.create_workspace(%{
        name: "Memory API #{unique}",
        slug: "memory-api-#{unique}"
      })

    {:ok, key} =
      Accounts.create_api_key(%{
        name: "agent-coder-#{unique}",
        workspace_ids: [{workspace.id, "write"}],
        created_by_user_id: owner.id
      })

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("accept", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{key.token}")

    %{
      conn: conn,
      owner: owner,
      workspace: workspace,
      key: key,
      unique: unique
    }
  end

  describe "POST /api/memory" do
    test "401 without token", %{workspace: workspace} do
      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("accept", "application/json")
        |> post("/api/memory", %{workspace: workspace.slug, content: "x"})

      assert %{"errors" => _} = json_response(conn, 401)
    end

    test "201 created with created_by from the API key", %{conn: conn, workspace: workspace} do
      stub_embeddings()

      conn =
        post(conn, "/api/memory", %{
          workspace: workspace.slug,
          content: "El scheduler corre cada noche"
        })

      assert %{"data" => memory, "duplicate" => false} = json_response(conn, 201)
      assert memory["content"] == "El scheduler corre cada noche"
      assert memory["created_by"] =~ "agent-coder-"
    end

    test "200 duplicate on re-add, row untouched", %{conn: conn, workspace: workspace} do
      stub_embeddings()

      params = %{workspace: workspace.slug, content: "hecho api único"}

      assert %{"duplicate" => false} = json_response(post(conn, "/api/memory", params), 201)

      assert %{"data" => dup, "duplicate" => true} =
               json_response(post(conn, "/api/memory", params), 200)

      assert dup["created_by"] =~ "agent-coder-"
    end

    test "422 on empty content", %{conn: conn, workspace: workspace} do
      stub_embeddings()

      conn = post(conn, "/api/memory", %{workspace: workspace.slug, content: "   "})
      assert %{"errors" => _} = json_response(conn, 422)
    end
  end

  describe "GET /api/memory/search" do
    test "returns matching facts with score", %{conn: conn, workspace: workspace} do
      stub_embeddings()
      post(conn, "/api/memory", %{workspace: workspace.slug, content: "El deploy es los viernes"})

      stub_embeddings()

      conn = get(conn, "/api/memory/search?q=deploy%20viernes&workspace=#{workspace.slug}")

      assert %{"data" => results} = json_response(conn, 200)
      assert length(results) >= 1
      assert hd(results)["content"] == "El deploy es los viernes"
      assert is_float(hd(results)["score"])
    end

    test "400 without q", %{conn: conn, workspace: workspace} do
      conn = get(conn, "/api/memory/search?workspace=#{workspace.slug}")
      assert %{"errors" => _} = json_response(conn, 400)
    end
  end

  describe "POST /api/memory/feedback" do
    test "adjusts trust score", %{conn: conn, workspace: workspace} do
      stub_embeddings()

      {:ok, memory, :created} =
        Memory.add(%{"workspace_id" => workspace.id, "content" => "fact para feedback"})

      conn =
        post(conn, "/api/memory/feedback", %{
          id: memory.id,
          helpful: true,
          workspace: workspace.slug
        })

      assert %{"data" => %{"trust_score" => score, "helpful_count" => 1}} =
               json_response(conn, 200)

      assert_in_delta score, 0.55, 0.0001
    end

    test "404 on unknown id", %{conn: conn, workspace: workspace} do
      conn =
        post(conn, "/api/memory/feedback", %{
          id: Ecto.UUID.generate(),
          helpful: false,
          workspace: workspace.slug
        })

      assert %{"errors" => _} = json_response(conn, 404)
    end

    test "404 cross-workspace: cannot rate a fact of another workspace", %{
      conn: conn,
      workspace: workspace
    } do
      unique = System.unique_integer([:positive])

      {:ok, other_ws} =
        Knowledge.create_workspace(%{name: "Other #{unique}", slug: "other-#{unique}"})

      stub_embeddings()

      {:ok, foreign, :created} =
        Memory.add(%{"workspace_id" => other_ws.id, "content" => "fact ajeno"})

      conn =
        post(conn, "/api/memory/feedback", %{
          id: foreign.id,
          helpful: true,
          workspace: workspace.slug
        })

      assert %{"errors" => _} = json_response(conn, 404)
      # The foreign row is untouched
      assert Memory.get_memory!(foreign.id).trust_score == 0.5
      assert Memory.get_memory!(foreign.id).helpful_count == 0
    end

    test "400 with invalid helpful", %{conn: conn, workspace: workspace} do
      stub_embeddings()

      {:ok, memory, :created} =
        Memory.add(%{"workspace_id" => workspace.id, "content" => "fact feedback dos"})

      conn =
        post(conn, "/api/memory/feedback", %{
          id: memory.id,
          helpful: "maybe",
          workspace: workspace.slug
        })

      assert %{"errors" => _} = json_response(conn, 400)
    end
  end

  describe "POST /api/memory/ingest" do
    test "extracts facts server-side and never stores the transcript", %{
      conn: conn,
      workspace: workspace
    } do
      transcript =
        Enum.map(1..5, fn i -> %{"role" => "user", "content" => "mensaje de relleno #{i}"} end) ++
          [%{"role" => "assistant", "content" => "ok"}]

      stub_chat(~s({"facts": ["Dran corre en Postgres 17", "El deploy es los viernes"]}))

      conn =
        post(conn, "/api/memory/ingest", %{
          workspace: workspace.slug,
          transcript: transcript,
          source_session: "sess-123"
        })

      assert %{"created" => 2, "duplicates" => 0, "facts" => facts} = json_response(conn, 200)
      assert "Dran corre en Postgres 17" in facts

      # Stored as memories with attribution + session
      memories = Memory.list_memories(workspace.id)
      assert length(memories) == 2
      assert hd(memories).source_session == "sess-123"
      assert hd(memories).created_by =~ "agent-coder-"
    end

    test "dedupes across ingests", %{conn: conn, workspace: workspace} do
      stub_chat(~s({"facts": ["hecho ingest repetido"]}))

      params = %{workspace: workspace.slug, transcript: "primera sesion"}

      assert %{"created" => 1} = json_response(post(conn, "/api/memory/ingest", params), 200)

      assert %{"created" => 0, "duplicates" => 1} =
               json_response(post(conn, "/api/memory/ingest", params), 200)
    end

    test "returns empty on extraction failure (invalid JSON from model)", %{
      conn: conn,
      workspace: workspace
    } do
      stub_chat("esto no es json")

      conn =
        post(conn, "/api/memory/ingest", %{workspace: workspace.slug, transcript: "sesion rara"})

      assert %{"facts" => [], "error" => "extraction_failed"} = json_response(conn, 200)
    end

    test "400 without transcript", %{conn: conn, workspace: workspace} do
      conn = post(conn, "/api/memory/ingest", %{workspace: workspace.slug})
      assert %{"errors" => _} = json_response(conn, 400)
    end
  end

  describe "DELETE /api/memory/:id" do
    test "404 cross-workspace: cannot delete a fact of another workspace", %{
      conn: conn,
      workspace: workspace
    } do
      unique = System.unique_integer([:positive])

      {:ok, other_ws} =
        Knowledge.create_workspace(%{name: "Other D #{unique}", slug: "other-d-#{unique}"})

      stub_embeddings()

      {:ok, foreign, :created} =
        Memory.add(%{"workspace_id" => other_ws.id, "content" => "fact ajeno a borrar"})

      conn = delete(conn, "/api/memory/#{foreign.id}?workspace=#{workspace.slug}")
      assert %{"errors" => _} = json_response(conn, 404)
      assert Memory.get_memory!(foreign.id).status == "active"
    end

    test "204 and fact leaves circulation", %{conn: conn, workspace: workspace} do
      stub_embeddings()

      {:ok, memory, :created} =
        Memory.add(%{"workspace_id" => workspace.id, "content" => "fact a borrar"})

      conn = delete(conn, "/api/memory/#{memory.id}?workspace=#{workspace.slug}")
      assert response(conn, 204) == ""

      updated = Memory.get_memory!(memory.id)
      assert updated.status == "superseded"
    end
  end

  # ── Stub helpers ─────────────────────────────────────────────────────

  defp stub_embeddings do
    Req.Test.stub(Dran.Inference.Client, fn conn ->
      if String.contains?(conn.request_path, "embeddings") do
        Req.Test.json(conn, embeddings_response())
      else
        Req.Test.json(conn, chat_response(~s({"facts": []})))
      end
    end)
  end

  defp stub_chat(content) do
    Req.Test.stub(Dran.Inference.Client, fn conn ->
      if String.contains?(conn.request_path, "embeddings") do
        Req.Test.json(conn, embeddings_response())
      else
        Req.Test.json(conn, chat_response(content))
      end
    end)
  end

  defp embeddings_response do
    %{
      "object" => "list",
      "data" => [
        %{"object" => "embedding", "index" => 0, "embedding" => List.duplicate(0.1, 1024)}
      ],
      "model" => "Qwen3-Embedding",
      "usage" => %{"prompt_tokens" => 2, "total_tokens" => 2}
    }
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
