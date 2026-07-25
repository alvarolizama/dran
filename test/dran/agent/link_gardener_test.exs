defmodule Dran.Agent.LinkGardenerTest do
  use Dran.DataCase, async: false

  alias Dran.{Brain, Repo}
  alias Dran.Agent.{LinkGardener, Session}
  alias Dran.Agent.LinkGardener.State
  alias Dran.Brain.Relation

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp build_session(attrs \\ []) do
    struct(
      %Session{
        id: Ecto.UUID.generate(),
        context_id: Ecto.UUID.generate(),
        agent_type: "link_gardener",
        input: "tend the graph",
        status: "running"
      },
      attrs
    )
  end

  defp build_state(attrs) do
    struct(
      %State{
        session: build_session(),
        pages_created: 0,
        opts: [],
        proposals_made: 0
      },
      attrs
    )
  end

  defp create_context! do
    {:ok, ctx} =
      Brain.create_context(%{name: "Test Context", slug: "test-ctx-#{:rand.uniform(999_999)}"})

    ctx
  end

  defp create_page!(ctx, attrs) do
    defaults = %{body: "some content", page_type: "concept", tags: []}
    attrs = Map.merge(defaults, attrs)

    {:ok, page} =
      Brain.create_page(%{
        context_id: ctx.id,
        title: attrs.title,
        slug: attrs.slug,
        body: attrs.body,
        page_type: attrs.page_type,
        tags: attrs.tags
      })

    page
  end

  defp get_relation!(id), do: Repo.get!(Relation, id)

  # ── Unit tests (no DB needed for limit/semantic guards) ───────────────────

  describe "agent_type/0" do
    test "returns link_gardener" do
      assert LinkGardener.agent_type() == "link_gardener"
    end
  end

  describe "tools/0" do
    test "exposes the expected tool names" do
      names =
        LinkGardener.tools()
        |> Enum.map(&get_in(&1, ["function", "name"]))
        |> Enum.sort()

      assert names ==
               [
                 "done",
                 "get_page",
                 "list_orphans",
                 "propose_relation",
                 "search",
                 "transitive_candidates"
               ]
    end

    test "propose_relation enum excludes semantic" do
      propose = Enum.find(LinkGardener.tools(), &(&1["function"]["name"] == "propose_relation"))

      enum = get_in(propose, ["function", "parameters", "properties", "relation_type", "enum"])

      assert "semantic" not in enum
      assert "part_of" in enum
      assert "supersedes" in enum
      assert "contradicts" in enum
      assert "related" in enum
    end
  end

  describe "propose_relation /2 — semantic rejection" do
    test "rejects relation_type semantic before hitting the DB" do
      ctx = create_context!()
      p1 = create_page!(ctx, %{title: "A", slug: "page-a"})
      p2 = create_page!(ctx, %{title: "B", slug: "page-b"})

      state = build_state(session: build_session(context_id: ctx.id))

      args = %{
        "source_slug" => p1.slug,
        "target_slug" => p2.slug,
        "relation_type" => "semantic",
        "justification" => "should be rejected"
      }

      {{:error, msg}, new_state} = LinkGardener.execute_tool("propose_relation", args, state)

      assert msg =~ "semantic"
      assert msg =~ "not allowed"
      # No proposal counted
      assert new_state.proposals_made == 0

      # No relation was created
      refute Repo.get_by(Relation, source_id: p1.id, target_id: p2.id)
    end
  end

  describe "propose_relation — proposal limit (10)" do
    test "returns error after 10 proposals" do
      ctx = create_context!()

      # Create enough pages so we can propose 10 distinct relations
      pages =
        for i <- 1..11 do
          create_page!(ctx, %{title: "Page #{i}", slug: "page-#{i}", body: "content #{i}"})
        end

      state = build_state(session: build_session(context_id: ctx.id), proposals_made: 10)

      args = %{
        "source_slug" => Enum.at(pages, 0).slug,
        "target_slug" => Enum.at(pages, 10).slug,
        "relation_type" => "related",
        "justification" => "one more"
      }

      {{:error, msg}, new_state} = LinkGardener.execute_tool("propose_relation", args, state)

      assert msg =~ "proposal limit reached"
      assert new_state.proposals_made == 10
    end
  end

  describe "propose_relation — creating a typed relation" do
    test "creates a relation with justification in meta" do
      ctx = create_context!()

      p1 =
        create_page!(ctx, %{
          title: "Overview",
          slug: "overview",
          body: "high-level overview of the system"
        })

      p2 =
        create_page!(ctx, %{
          title: "Architecture",
          slug: "architecture",
          body: "detailed architecture doc"
        })

      state = build_state(session: build_session(context_id: ctx.id))

      args = %{
        "source_slug" => p1.slug,
        "target_slug" => p2.slug,
        "relation_type" => "part_of",
        "justification" => "Overview references the architecture section"
      }

      {{:ok, result}, new_state} = LinkGardener.execute_tool("propose_relation", args, state)

      # The returned result references the created relation
      assert result.relation_type == "part_of"
      assert result.source_slug == "overview"
      assert result.target_slug == "architecture"
      assert result.justification == "Overview references the architecture section"

      # proposals_made incremented
      assert new_state.proposals_made == 1

      # The relation exists in the DB with the right meta
      relation = get_relation!(result.id)
      assert relation.relation_type == "part_of"
      assert relation.source_id == p1.id
      assert relation.target_id == p2.id
      assert relation.meta["justification"] == "Overview references the architecture section"
      assert relation.meta["proposed_by"] == "link-gardener"
    end

    test "rejects unknown relation_type" do
      ctx = create_context!()
      p1 = create_page!(ctx, %{title: "A", slug: "a"})
      p2 = create_page!(ctx, %{title: "B", slug: "b"})

      state = build_state(session: build_session(context_id: ctx.id))

      args = %{
        "source_slug" => p1.slug,
        "target_slug" => p2.slug,
        "relation_type" => "nonsense_type",
        "justification" => "bad type"
      }

      {{:error, msg}, new_state} = LinkGardener.execute_tool("propose_relation", args, state)

      assert msg =~ "invalid relation_type"
      assert new_state.proposals_made == 0
    end

    test "rejects when source page not found" do
      ctx = create_context!()
      p2 = create_page!(ctx, %{title: "B", slug: "b"})

      state = build_state(session: build_session(context_id: ctx.id))

      args = %{
        "source_slug" => "does-not-exist",
        "target_slug" => p2.slug,
        "relation_type" => "related",
        "justification" => "x"
      }

      {{:error, msg}, _} = LinkGardener.execute_tool("propose_relation", args, state)
      assert msg =~ "source page"
      assert msg =~ "not found"
    end

    test "rejects when source and target are the same page" do
      ctx = create_context!()
      p1 = create_page!(ctx, %{title: "Same", slug: "same"})

      state = build_state(session: build_session(context_id: ctx.id))

      args = %{
        "source_slug" => p1.slug,
        "target_slug" => p1.slug,
        "relation_type" => "related",
        "justification" => "self"
      }

      {{:error, msg}, new_state} = LinkGardener.execute_tool("propose_relation", args, state)

      assert msg =~ "different pages"
      assert new_state.proposals_made == 0
    end
  end

  describe "list_orphans" do
    test "returns orphan pages for the session context" do
      ctx = create_context!()
      p1 = create_page!(ctx, %{title: "Orphan", slug: "orphan"})
      p2 = create_page!(ctx, %{title: "Linked", slug: "linked"})

      # Create a relation pointing at p2 so it is not an orphan
      {:ok, _} =
        Brain.create_relation(%{
          source_id: p1.id,
          target_id: p2.id,
          relation_type: "related"
        })

      state = build_state(session: build_session(context_id: ctx.id))

      {{:ok, orphans}, _} = LinkGardener.execute_tool("list_orphans", %{}, state)

      orphan_slugs = Enum.map(orphans, & &1.slug)
      # p1 is the source of a relation, p2 is the target.
      # orphan_pages filters out pages that appear as a *target* of any relation.
      # So p1 (only a source) is an orphan, p2 (a target) is not.
      assert "orphan" in orphan_slugs
      refute "linked" in orphan_slugs
    end
  end

  describe "get_page" do
    test "returns the page content as a map" do
      ctx = create_context!()
      create_page!(ctx, %{title: "My Page", slug: "my-page", body: "hello world"})

      state = build_state(session: build_session(context_id: ctx.id))

      {{:ok, page}, _} = LinkGardener.execute_tool("get_page", %{"slug" => "my-page"}, state)

      assert page.slug == "my-page"
      assert page.title == "My Page"
      assert page.body == "hello world"
    end

    test "returns error for unknown slug" do
      ctx = create_context!()
      state = build_state(session: build_session(context_id: ctx.id))

      {{:error, msg}, _} = LinkGardener.execute_tool("get_page", %{"slug" => "nope"}, state)
      assert msg =~ "not found"
    end
  end

  describe "transitive_candidates" do
    test "returns transitive part_of candidates with via_slug evidence" do
      ctx = create_context!()

      a = create_page!(ctx, %{title: "Alpha", slug: "alpha-t"})
      b = create_page!(ctx, %{title: "Beta", slug: "beta-t"})
      c = create_page!(ctx, %{title: "Gamma", slug: "gamma-t"})

      # A part_of B, B part_of C  →  candidate: A part_of C (via B)
      {:ok, _} =
        Brain.create_relation(%{
          source_id: a.id,
          target_id: b.id,
          relation_type: "part_of"
        })

      {:ok, _} =
        Brain.create_relation(%{
          source_id: b.id,
          target_id: c.id,
          relation_type: "part_of"
        })

      state = build_state(session: build_session(context_id: ctx.id))

      {{:ok, candidates}, _new_state} =
        LinkGardener.execute_tool("transitive_candidates", %{}, state)

      assert is_list(candidates)

      expected = %{source_slug: "alpha-t", target_slug: "gamma-t", via_slug: "beta-t"}

      assert expected in candidates,
             "expected transitive candidate #{inspect(expected)} in #{inspect(candidates)}"
    end

    test "does not return a candidate when the direct edge already exists" do
      ctx = create_context!()

      a = create_page!(ctx, %{title: "A", slug: "a-direct"})
      b = create_page!(ctx, %{title: "B", slug: "b-direct"})
      c = create_page!(ctx, %{title: "C", slug: "c-direct"})

      {:ok, _} =
        Brain.create_relation(%{
          source_id: a.id,
          target_id: b.id,
          relation_type: "part_of"
        })

      {:ok, _} =
        Brain.create_relation(%{
          source_id: b.id,
          target_id: c.id,
          relation_type: "part_of"
        })

      # Direct edge A→C already exists, so (A, C, via B) must NOT be a candidate.
      {:ok, _} =
        Brain.create_relation(%{
          source_id: a.id,
          target_id: c.id,
          relation_type: "part_of"
        })

      state = build_state(session: build_session(context_id: ctx.id))

      {{:ok, candidates}, _new_state} =
        LinkGardener.execute_tool("transitive_candidates", %{}, state)

      refute %{source_slug: "a-direct", target_slug: "c-direct", via_slug: "b-direct"} in candidates,
             "direct edge already exists; should not be a candidate: #{inspect(candidates)}"
    end

    test "returns empty list when context has no part_of chains" do
      ctx = create_context!()

      # Only a related edge — not part_of.
      p1 = create_page!(ctx, %{title: "X", slug: "x"})
      p2 = create_page!(ctx, %{title: "Y", slug: "y"})

      {:ok, _} =
        Brain.create_relation(%{
          source_id: p1.id,
          target_id: p2.id,
          relation_type: "related"
        })

      state = build_state(session: build_session(context_id: ctx.id))

      {{:ok, candidates}, _new_state} =
        LinkGardener.execute_tool("transitive_candidates", %{}, state)

      assert candidates == []
    end
  end

  describe "system_prompt/0" do
    test "mentions the 10 proposal limit and forbids semantic" do
      prompt = LinkGardener.system_prompt()
      assert prompt =~ "10"
      assert prompt =~ "semantic"
      assert prompt =~ "NEVER"
    end
  end

  # ── E2E test with Req.Test stub ───────────────────────────────────────────
  #
  # Drives the full LinkGardener flow: list_orphans → get_page →
  # propose_relation → done. We exercise the agent's execute_tool/3
  # directly in sequence (the same path the engine's single_turn takes),
  # and use a Req.Test stub for the LLM to verify the engine end-to-end
  # would receive valid tool-call responses.

  describe "E2E flow with Req.Test stub" do
    @describetag :e2e

    test "list_orphans → get_page → propose_relation → done creates a relation" do
      # Disable inference while creating pages so PageAugmenter.schedule
      # returns :ignored (no async task spawned that would consume stub
      # responses or lose sandbox ownership). The test shell may have
      # inference enabled via env vars (runtime.exs loads it in all envs).
      original = Application.get_env(:dran, :inference)
      Application.delete_env(:dran, :inference)

      ctx = create_context!()

      p1 = create_page!(ctx, %{title: "Alpha", slug: "alpha", body: "alpha content"})
      p2 = create_page!(ctx, %{title: "Beta", slug: "beta", body: "beta content"})

      {:ok, _} =
        Brain.create_relation(%{
          source_id: p1.id,
          target_id: p2.id,
          relation_type: "related"
        })

      # Now enable inference with a Req.Test stub for the chat endpoint.

      Application.put_env(:dran, :inference,
        base_url: "http://localhost:8000/v1",
        api_key: "test-key",
        chat_model: "Ornith-1.0-9B",
        embedding_model: "Qwen3-Embedding",
        rerank_model: "Qwen3-Reranker",
        timeout: 5_000,
        schedule_async: false,
        req_plug: {Req.Test, Dran.Inference.Client}
      )

      on_exit(fn ->
        if is_nil(original) do
          Application.delete_env(:dran, :inference)
        else
          Application.put_env(:dran, :inference, original)
        end
      end)

      # Scripted LLM responses for each step. We stub the chat endpoint
      # to return these in sequence, and verify Inference.chat returns
      # the expected tool calls.
      responses = [
        chat_response("call_1", "list_orphans", %{}),
        chat_response("call_2", "get_page", %{"slug" => "alpha"}),
        chat_response("call_3", "propose_relation", %{
          "source_slug" => "beta",
          "target_slug" => "alpha",
          "relation_type" => "supersedes",
          "justification" => "Beta supersedes Alpha per content"
        }),
        chat_response("call_4", "done", %{"summary" => "Proposed 1 relation"})
      ]

      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(Dran.Inference.Client, fn conn ->
        {:ok, _body, conn} = Plug.Conn.read_body(conn)

        idx = Agent.get_and_update(counter, fn i -> {i, i + 1} end)
        response = chat_completion(Enum.at(responses, idx))
        Req.Test.json(conn, response)
      end)

      # Step 1: list_orphans via the LLM stub → execute_tool
      {:ok, message1} = Dran.Inference.chat(%{"model" => "Ornith-1.0-9B", "messages" => []})
      {tool1, args1} = extract_tool_from_message(message1)
      assert tool1 == "list_orphans"

      state =
        LinkGardener.init_state(
          struct!(Session, %{
            id: Ecto.UUID.generate(),
            context_id: ctx.id,
            agent_type: "link_gardener",
            input: "tend links",
            status: "running"
          }),
          LinkGardener,
          []
        )

      {result1, state} = LinkGardener.execute_tool(tool1, args1, state)
      assert match?({:ok, [_ | _]}, result1) or match?({:ok, []}, result1)
      orphan_slugs = Enum.map(elem(result1, 1), & &1.slug)
      assert "alpha" in orphan_slugs

      # Step 2: get_page(alpha)
      {:ok, message2} = Dran.Inference.chat(%{"model" => "Ornith-1.0-9B", "messages" => []})
      {tool2, args2} = extract_tool_from_message(message2)
      assert tool2 == "get_page"

      {result2, state} = LinkGardener.execute_tool(tool2, args2, state)
      {:ok, page_data} = result2
      assert page_data.slug == "alpha"
      assert page_data.body == "alpha content"

      # Step 3: propose_relation(beta → alpha, supersedes)
      {:ok, message3} = Dran.Inference.chat(%{"model" => "Ornith-1.0-9B", "messages" => []})
      {tool3, args3} = extract_tool_from_message(message3)
      assert tool3 == "propose_relation"

      {result3, state} = LinkGardener.execute_tool(tool3, args3, state)
      {:ok, relation_result} = result3
      assert relation_result.relation_type == "supersedes"
      assert relation_result.source_slug == "beta"
      assert relation_result.target_slug == "alpha"
      assert state.proposals_made == 1

      # Step 4: done
      {:ok, message4} = Dran.Inference.chat(%{"model" => "Ornith-1.0-9B", "messages" => []})
      {tool4, _args4} = extract_tool_from_message(message4)
      assert tool4 == "done"

      {{:ok, :done}, _state} = LinkGardener.execute_tool("done", %{}, state)

      # Verify the relation was persisted in the DB with the right meta
      rel =
        Repo.get_by(Relation, source_id: p2.id, target_id: p1.id, relation_type: "supersedes")

      assert rel != nil, "expected supersedes relation beta → alpha to be created"
      assert rel.meta["justification"] == "Beta supersedes Alpha per content"
      assert rel.meta["proposed_by"] == "link-gardener"
    end
  end

  # ── E2E helpers ───────────────────────────────────────────────────────────

  defp chat_response(tool_call_id, tool_name, args) do
    %{
      "tool_call_id" => tool_call_id,
      "tool_name" => tool_name,
      "args" => args
    }
  end

  defp extract_tool_from_message(message) do
    [%{"function" => %{"name" => name, "arguments" => args_str}} | _] =
      Map.get(message, "tool_calls", [])

    {:ok, args} = Jason.decode(args_str)
    {name, args}
  end

  defp chat_completion(%{
         "tool_call_id" => id,
         "tool_name" => name,
         "args" => args
       }) do
    %{
      "id" => "chatcmpl-#{id}",
      "object" => "chat.completion",
      "model" => "Ornith-1.0-9B",
      "choices" => [
        %{
          "index" => 0,
          "message" => %{
            "role" => "assistant",
            "content" => "Calling #{name}",
            "tool_calls" => [
              %{
                "id" => id,
                "type" => "function",
                "function" => %{
                  "name" => name,
                  "arguments" => Jason.encode!(args)
                }
              }
            ]
          },
          "finish_reason" => "tool_calls"
        }
      ],
      "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 10, "total_tokens" => 20}
    }
  end
end
