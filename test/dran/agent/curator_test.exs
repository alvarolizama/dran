defmodule Dran.Agent.CuratorTest do
  # Tests for Dran.Agent.Curator.
  #
  # Three layers:
  #   1. Unit test for find_duplicates — seeds pages with synthetic embeddings
  #      and verifies the self-join returns only the close pair.
  #   2. Unit test for flag_contested — verifies kb_contested is set to true.
  #   3. E2E test with Req.Test stub — the LLM calls find_duplicates →
  #      flag_contested → create_note → done; verifies the note was created
  #      and the flags were applied.
  use Dran.DataCase, async: false

  alias Dran.Agent.{Curator, Session}
  alias Dran.{Brain, Repo}
  alias Dran.Brain.Page

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp build_session(context_id) do
    struct(%Session{
      id: Ecto.UUID.generate(),
      context_id: context_id,
      agent_type: "curator",
      input: "test curator run",
      status: "running"
    })
  end

  defp build_state(context_id, attrs \\ []) do
    struct(
      %Curator.State{
        session: build_session(context_id),
        pages_created: 0,
        opts: [],
        duplicate_pairs: [],
        flags_made: 0
      },
      attrs
    )
  end

  defp insert_page!(context_id, attrs) do
    %Page{
      context_id: context_id,
      title: attrs[:title] || "Test page",
      slug: attrs[:slug] || "test-#{:rand.uniform(999_999)}",
      body: attrs[:body] || "test body",
      page_type: attrs[:page_type] || "note",
      embedding_hash: attrs[:embedding_hash] || "hash-#{:rand.uniform(999_999)}",
      embedding: attrs[:embedding],
      meta: attrs[:meta] || %{}
    }
    |> Repo.insert!()
  end

  # Two vectors that are very close (distance < 0.05) and one that is far.
  # The embedding column is configured for 1024 dimensions.
  # close_vector_b differs from close_vector_a only in dimension 0 (1.0 vs 0.999),
  # giving a cosine distance well below 0.05.
  # far_vector is orthogonal, giving distance ~1.0.
  defp close_vector_a, do: List.duplicate(0.0, 1023) ++ [1.0]
  defp close_vector_b, do: List.duplicate(0.0, 1023) ++ [0.999]
  defp far_vector, do: [1.0] ++ List.duplicate(0.0, 1023)

  defp ensure_context! do
    Brain.get_context_by_slug("personal") ||
      elem(Brain.create_context(%{name: "Personal", slug: "personal"}), 1)
  end

  # ── Unit test: find_duplicates ────────────────────────────────────────────

  describe "find_duplicates" do
    setup do
      # Inference disabled so Brain.create_page (if called) doesn't hit the API.
      original = Application.get_env(:dran, :inference)

      Application.put_env(:dran, :inference,
        base_url: nil,
        api_key: nil,
        timeout: 100,
        schedule_async: false
      )

      on_exit(fn ->
        if is_nil(original) do
          Application.delete_env(:dran, :inference)
        else
          Application.put_env(:dran, :inference, original)
        end
      end)

      context = ensure_context!()
      {:ok, context: context}
    end

    test "returns only the close pair, not the far page", %{context: ctx} do
      # Insert two pages with very close embeddings
      _page_a =
        insert_page!(ctx.id,
          title: "Page A",
          slug: "page-a",
          embedding: Pgvector.new(close_vector_a())
        )

      _page_b =
        insert_page!(ctx.id,
          title: "Page B",
          slug: "page-b",
          embedding: Pgvector.new(close_vector_b())
        )

      # Insert a page with a far embedding
      _page_c =
        insert_page!(ctx.id,
          title: "Page C",
          slug: "page-c",
          embedding: Pgvector.new(far_vector())
        )

      state = build_state(ctx.id)
      {{:ok, pairs}, new_state} = Curator.execute_tool("find_duplicates", %{}, state)

      # Should find exactly one pair: page_a and page_b
      assert length(pairs) == 1

      pair = hd(pairs)
      assert pair.a.slug in ["page-a", "page-b"]
      assert pair.b.slug in ["page-a", "page-b"]
      assert pair.a.slug != pair.b.slug
      assert pair.distance < 0.05

      # State should store the duplicate pairs
      assert new_state.duplicate_pairs == pairs
    end

    test "returns empty list when no pages have embeddings", %{context: ctx} do
      # Insert pages without embeddings
      _page =
        insert_page!(ctx.id,
          title: "No Embed",
          slug: "no-embed",
          embedding: nil,
          embedding_hash: nil
        )

      state = build_state(ctx.id)
      {{:ok, pairs}, new_state} = Curator.execute_tool("find_duplicates", %{}, state)

      assert pairs == []
      assert new_state.duplicate_pairs == []
    end

    test "enriches pairs with same_community flag when both pages share a community_id", %{
      context: ctx
    } do
      # Two pages with close embeddings AND the same community_id in meta.
      _page_a =
        insert_page!(ctx.id,
          title: "Page A",
          slug: "comm-a",
          embedding: Pgvector.new(close_vector_a()),
          meta: %{"community_id" => 7}
        )

      _page_b =
        insert_page!(ctx.id,
          title: "Page B",
          slug: "comm-b",
          embedding: Pgvector.new(close_vector_b()),
          meta: %{"community_id" => 7}
        )

      state = build_state(ctx.id)
      {{:ok, pairs}, _new_state} = Curator.execute_tool("find_duplicates", %{}, state)

      assert length(pairs) == 1
      pair = hd(pairs)

      # The pair must carry the same_community flag set to true.
      assert pair.same_community == true
      # And the meta must NOT be leaked into the pair payload.
      refute Map.has_key?(pair.a, :meta)
      refute Map.has_key?(pair.b, :meta)
    end

    test "sets same_community to false when pages are in different communities", %{context: ctx} do
      _page_a =
        insert_page!(ctx.id,
          title: "Page A",
          slug: "diff-comm-a",
          embedding: Pgvector.new(close_vector_a()),
          meta: %{"community_id" => 1}
        )

      _page_b =
        insert_page!(ctx.id,
          title: "Page B",
          slug: "diff-comm-b",
          embedding: Pgvector.new(close_vector_b()),
          meta: %{"community_id" => 2}
        )

      state = build_state(ctx.id)
      {{:ok, pairs}, _new_state} = Curator.execute_tool("find_duplicates", %{}, state)

      assert length(pairs) == 1
      pair = hd(pairs)
      assert pair.same_community == false
    end

    test "sets same_community to false when community_id is missing", %{context: ctx} do
      # Pages with close embeddings but no community_id in meta (communities
      # not yet refreshed). same_community must be false, not crash.
      _page_a =
        insert_page!(ctx.id,
          title: "Page A",
          slug: "no-comm-a",
          embedding: Pgvector.new(close_vector_a())
        )

      _page_b =
        insert_page!(ctx.id,
          title: "Page B",
          slug: "no-comm-b",
          embedding: Pgvector.new(close_vector_b())
        )

      state = build_state(ctx.id)
      {{:ok, pairs}, _new_state} = Curator.execute_tool("find_duplicates", %{}, state)

      assert length(pairs) == 1
      pair = hd(pairs)
      assert pair.same_community == false
    end
  end

  # ── Unit test: flag_contested ──────────────────────────────────────────────

  describe "flag_contested" do
    setup do
      original = Application.get_env(:dran, :inference)

      Application.put_env(:dran, :inference,
        base_url: nil,
        api_key: nil,
        timeout: 100,
        schedule_async: false
      )

      on_exit(fn ->
        if is_nil(original) do
          Application.delete_env(:dran, :inference)
        else
          Application.put_env(:dran, :inference, original)
        end
      end)

      context = ensure_context!()
      {:ok, context: context}
    end

    test "sets kb_contested to true on flagged pages", %{context: ctx} do
      page1 = insert_page!(ctx.id, title: "Page 1", slug: "flag-1")
      page2 = insert_page!(ctx.id, title: "Page 2", slug: "flag-2")

      # Verify initial state
      refute Repo.get(Page, page1.id).kb_contested
      refute Repo.get(Page, page2.id).kb_contested

      state = build_state(ctx.id)

      {{:ok, result}, new_state} =
        Curator.execute_tool("flag_contested", %{"slugs" => ["flag-1", "flag-2"]}, state)

      assert result.flagged == ["flag-1", "flag-2"]
      assert result.errors == []
      assert result.total_flags_this_session == 2
      assert new_state.flags_made == 2

      # Verify DB was updated
      assert Repo.get(Page, page1.id).kb_contested == true
      assert Repo.get(Page, page2.id).kb_contested == true
    end

    test "returns error for non-existent slugs", %{context: ctx} do
      state = build_state(ctx.id)

      {{:ok, result}, _new_state} =
        Curator.execute_tool("flag_contested", %{"slugs" => ["does-not-exist"]}, state)

      assert result.flagged == []
      assert result.errors == ["page 'does-not-exist' not found"]
    end

    test "respects the 20-flag limit", %{context: ctx} do
      state = build_state(ctx.id, flags_made: 20)

      {{:error, msg}, _new_state} =
        Curator.execute_tool("flag_contested", %{"slugs" => ["some-slug"]}, state)

      assert msg =~ "flag limit reached"
    end
  end

  # ── E2E test with Req.Test stub ────────────────────────────────────────────

  describe "E2E: LLM calls find_duplicates → flag_contested → create_note → done" do
    setup do
      original = Application.get_env(:dran, :inference)

      Application.put_env(:dran, :inference,
        base_url: "http://localhost:8000/v1",
        api_key: "test-key",
        chat_model: "test-chat-model",
        embedding_model: "Qwen3-Embedding",
        timeout: 5_000,
        req_plug: {Req.Test, Dran.Inference.Client},
        schedule_async: false
      )

      # Ensure the inference queue GenServers are running
      ensure_queue_started(:chat)
      ensure_queue_started(:embed)

      context = ensure_context!()

      # Seed two pages with close embeddings so find_duplicates returns them
      insert_page!(context.id,
        title: "Duplicate A",
        slug: "dup-a",
        body: "content about elixir",
        embedding: Pgvector.new(close_vector_a())
      )

      insert_page!(context.id,
        title: "Duplicate B",
        slug: "dup-b",
        body: "content about elixir",
        embedding: Pgvector.new(close_vector_b())
      )

      on_exit(fn ->
        if is_nil(original) do
          Application.delete_env(:dran, :inference)
        else
          Application.put_env(:dran, :inference, original)
        end
      end)

      {:ok, context: context}
    end

    test "full curator workflow creates a report note and flags duplicates", %{context: ctx} do
      # The LLM stub simulates a 4-step conversation:
      # Step 1: call find_duplicates
      # Step 2: call flag_contested with the duplicate slugs
      # Step 3: call create_note with a report body
      # Step 4: call done
      #
      # We use a counter to serve different responses on each call.
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(Dran.Inference.Client, fn conn ->
        case conn.request_path do
          "/v1/embeddings" ->
            # Answer embedding requests (from Brain.create_page on create_note)
            Req.Test.json(conn, %{
              "object" => "list",
              "data" => [
                %{"object" => "embedding", "index" => 0, "embedding" => List.duplicate(0.0, 1024)}
              ]
            })

          "/v1/chat/completions" ->
            step = Agent.get_and_update(counter, fn s -> {s, s + 1} end)

            tool_call =
              case step do
                0 ->
                  %{
                    "id" => "call-1",
                    "type" => "function",
                    "function" => %{
                      "name" => "find_duplicates",
                      "arguments" => "{}"
                    }
                  }

                1 ->
                  %{
                    "id" => "call-2",
                    "type" => "function",
                    "function" => %{
                      "name" => "flag_contested",
                      "arguments" => ~s({"slugs": ["dup-a", "dup-b"]})
                    }
                  }

                2 ->
                  %{
                    "id" => "call-3",
                    "type" => "function",
                    "function" => %{
                      "name" => "create_note",
                      "arguments" =>
                        ~s({"body": "## Curator Report\\n\\nReviewed 1 duplicate pair. Flagged dup-a and dup-b as contested."})
                    }
                  }

                _ ->
                  %{
                    "id" => "call-4",
                    "type" => "function",
                    "function" => %{
                      "name" => "done",
                      "arguments" => ~s({"summary": "Reviewed duplicates and created report."})
                    }
                  }
              end

            Req.Test.json(conn, %{
              "id" => "chat-#{step}",
              "object" => "chat.completion",
              "model" => "test-chat-model",
              "choices" => [
                %{
                  "message" => %{
                    "role" => "assistant",
                    "content" => "",
                    "tool_calls" => [tool_call]
                  }
                }
              ],
              "usage" => %{"total_tokens" => 100}
            })
        end
      end)

      {:ok, session} = Curator.run("scheduled run", ctx.id)

      # Wait for the async agent to finish
      assert eventually(fn ->
               s = Repo.get(Session, session.id)
               s.status == "done"
             end)

      # Verify the session completed successfully
      session = Repo.get(Session, session.id)
      assert session.status == "done"
      assert session.summary =~ "Reviewed duplicates"

      # Verify the note was created
      date_str = Date.utc_today() |> Date.to_iso8601()
      note = Brain.get_page_by_slug("curator-report-" <> date_str, ctx.id)
      assert note != nil
      assert note.title =~ "Curator report"
      assert note.created_by == "curator"
      assert note.body =~ "Curator Report"

      # Verify the pages were flagged as contested
      page_a = Brain.get_page_by_slug("dup-a", ctx.id)
      page_b = Brain.get_page_by_slug("dup-b", ctx.id)
      assert page_a.kb_contested == true
      assert page_b.kb_contested == true

      Agent.stop(counter)
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp ensure_queue_started(capability) do
    case Registry.start_link(keys: :unique, name: Dran.Inference.QueueRegistry) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    case Dran.Inference.Queue.start_link(capability: capability) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(100)
      eventually(fun, attempts - 1)
    end
  end
end
