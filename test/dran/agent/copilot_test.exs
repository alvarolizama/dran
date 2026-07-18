defmodule Dran.Agent.CopilotTest do
  use Dran.DataCase, async: false

  alias Dran.Agent.Copilot
  alias Dran.Agent.Copilot.State
  alias Dran.Agent.Session
  alias Dran.{Brain, MCP}

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp build_session(attrs \\ []) do
    struct(
      %Session{
        id: Ecto.UUID.generate(),
        context_id: Ecto.UUID.generate(),
        agent_type: "copilot",
        input: "test question",
        status: "running",
        meta: %{}
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
        sources: []
      },
      attrs
    )
  end

  defp create_context! do
    {:ok, ctx} =
      Brain.create_context(%{name: "Test", slug: "test-ctx-#{:rand.uniform(999_999)}"})

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

  # ── agent_type/0 ──────────────────────────────────────────────────────────

  describe "agent_type/0" do
    test "returns copilot" do
      assert Copilot.agent_type() == "copilot"
    end
  end

  # ── tools/0 ───────────────────────────────────────────────────────────────

  describe "tools/0" do
    test "returns a non-empty list of OpenAI function schemas" do
      tools = Copilot.tools()
      assert is_list(tools)
      assert length(tools) == 19
    end

    test "each tool has the correct OpenAI function structure" do
      for tool <- Copilot.tools() do
        assert tool["type"] == "function"
        assert is_binary(tool["function"]["name"])
        assert is_binary(tool["function"]["description"])
        assert is_map(tool["function"]["parameters"])
      end
    end

    test "includes all 18 MCP tool names" do
      names = Enum.map(Copilot.tools(), & &1["function"]["name"])

      expected_mcp_tools = [
        "dran_search",
        "dran_create_page",
        "dran_update_page",
        "dran_get_page",
        "dran_delete_page",
        "dran_create_todo",
        "dran_update_todo",
        "dran_create_relation",
        "dran_delete_relation",
        "dran_get_links",
        "dran_list_pages",
        "dran_get_stats",
        "dran_lint_brain",
        "dran_rename_slug",
        "dran_reaugment_page",
        "dran_ingest_url",
        "dran_start_agent",
        "dran_get_agent_session"
      ]

      for name <- expected_mcp_tools do
        assert name in names, "expected #{name} in tools"
      end
    end

    test "includes the done tool" do
      names = Enum.map(Copilot.tools(), & &1["function"]["name"])
      assert "done" in names
    end

    test "done tool requires summary" do
      done = Enum.find(Copilot.tools(), &(&1["function"]["name"] == "done"))
      required = done["function"]["parameters"]["required"]
      assert "summary" in required
    end

    test "dran_search parameters include query and context" do
      search = Enum.find(Copilot.tools(), &(&1["function"]["name"] == "dran_search"))
      props = search["function"]["parameters"]["properties"]
      assert Map.has_key?(props, "query")
      assert Map.has_key?(props, "context")
    end
  end

  # ── system_prompt/0 ───────────────────────────────────────────────────────

  describe "system_prompt/0" do
    test "mentions second brain" do
      assert Copilot.system_prompt() =~ "second brain"
    end

    test "mentions key tools" do
      prompt = Copilot.system_prompt()
      assert prompt =~ "dran_search"
      assert prompt =~ "dran_get_page"
      assert prompt =~ "done"
    end

    test "instructs to respond in Spanish" do
      assert Copilot.system_prompt() =~ "español"
    end
  end

  # ── build_messages/2 ──────────────────────────────────────────────────────

  describe "build_messages/2" do
    test "includes system, user message, and context" do
      session = build_session(meta: %{"context_slug" => "work"})
      messages = Copilot.build_messages("What is Elixir?", session)

      [%{"role" => "system"} | _rest] = messages
      assert hd(messages)["content"] =~ "second brain"
      assert hd(messages)["content"] =~ "Contexto actual: work"

      last = List.last(messages)
      assert last["role"] == "user"
      assert last["content"] == "What is Elixir?"
    end

    test "includes page_slug in system message when present" do
      session =
        build_session(meta: %{"context_slug" => "personal", "page_slug" => "my-page"})

      messages = Copilot.build_messages("question", session)

      system = hd(messages)
      assert system["content"] =~ "Página actual: my-page"
    end

    test "does not include page_slug when absent" do
      session = build_session(meta: %{"context_slug" => "personal"})
      messages = Copilot.build_messages("question", session)

      system = hd(messages)
      refute system["content"] =~ "Página actual"
    end

    test "includes history messages" do
      history = [
        %{"role" => "user", "content" => "previous question"},
        %{"role" => "assistant", "content" => "previous answer"}
      ]

      session = build_session(meta: %{"history" => history})
      messages = Copilot.build_messages("new question", session)

      # system + 2 history + user = 4
      assert length(messages) == 4
      assert Enum.at(messages, 1)["content"] == "previous question"
      assert Enum.at(messages, 2)["content"] == "previous answer"
    end

    test "limits history to last 10 messages" do
      history =
        for i <- 1..15 do
          %{"role" => "user", "content" => "msg #{i}"}
        end

      session = build_session(meta: %{"history" => history})
      messages = Copilot.build_messages("new", session)

      # system + 10 history + user = 12
      assert length(messages) == 12
    end

    test "defaults context_slug to personal" do
      session = build_session(meta: %{})
      messages = Copilot.build_messages("question", session)

      assert hd(messages)["content"] =~ "Contexto actual: personal"
    end

    test "handles nil meta gracefully" do
      session = build_session(meta: nil)
      messages = Copilot.build_messages("question", session)

      assert is_list(messages)
      assert hd(messages)["role"] == "system"
    end
  end

  # ── init_state/3 ──────────────────────────────────────────────────────────

  describe "init_state/3" do
    test "returns a State struct with messages" do
      session = build_session(meta: %{"context_slug" => "personal"})
      state = Copilot.init_state(session, Copilot, [])

      assert %State{} = state
      assert state.session == session
      assert state.module == Copilot
      assert is_list(state.messages)
      assert state.step == 0
      assert state.sources == []
    end

    test "messages include system and user" do
      session = build_session(input: "hello world", meta: %{"context_slug" => "personal"})
      state = Copilot.init_state(session, Copilot, test: true)

      assert hd(state.messages)["role"] == "system"
      assert List.last(state.messages)["content"] == "hello world"
    end

    test "passes opts through" do
      session = build_session(meta: %{})
      state = Copilot.init_state(session, Copilot, foo: "bar")
      assert state.opts == [foo: "bar"]
    end
  end

  # ── execute_tool/3 — done ─────────────────────────────────────────────────

  describe "execute_tool/3 — done" do
    test "returns {:ok, :done} and unchanged state" do
      state = build_state([])
      {{:ok, :done}, new_state} = Copilot.execute_tool("done", %{"summary" => "test"}, state)
      assert new_state == state
    end
  end

  # ── execute_tool/3 — context injection ────────────────────────────────────

  describe "execute_tool/3 — context injection" do
    test "injects context_slug from session meta" do
      ctx = create_context!()
      create_page!(ctx, %{title: "Test", slug: "test-page", body: "hello world"})

      session = build_session(context_id: ctx.id, meta: %{"context_slug" => ctx.slug})
      state = build_state(session: session)

      # dran_get_page without "context" in args — should be injected
      {{:ok, result}, _} =
        Copilot.execute_tool("dran_get_page", %{"slug" => "test-page"}, state)

      assert result =~ "hello world"
    end

    test "does not override context if already present in args" do
      ctx = create_context!()
      create_page!(ctx, %{title: "Test", slug: "test-page", body: "hello world"})

      # Session meta has a different (nonexistent) context slug
      session = build_session(context_id: ctx.id, meta: %{"context_slug" => "nonexistent"})
      state = build_state(session: session)

      # Pass "context" explicitly — should use the passed value, not session meta
      {{:ok, result}, _} =
        Copilot.execute_tool(
          "dran_get_page",
          %{"slug" => "test-page", "context" => ctx.slug},
          state
        )

      assert result =~ "hello world"
    end

    test "defaults to personal when context_slug not in meta" do
      session = build_session(meta: %{})
      state = build_state(session: session)

      # Should try to use "personal" context, which doesn't exist in test DB
      {{:error, msg}, _} = Copilot.execute_tool("dran_get_page", %{"slug" => "test"}, state)
      assert msg =~ "Error"
    end
  end

  # ── execute_tool/3 — MCP tools ────────────────────────────────────────────

  describe "execute_tool/3 — MCP tools" do
    setup do
      ctx = create_context!()
      {:ok, context: ctx}
    end

    test "dran_get_page returns page content", %{context: ctx} do
      create_page!(ctx, %{title: "My Page", slug: "my-page", body: "hello world"})

      session = build_session(context_id: ctx.id, meta: %{"context_slug" => ctx.slug})
      state = build_state(session: session)

      {{:ok, result}, new_state} =
        Copilot.execute_tool("dran_get_page", %{"slug" => "my-page"}, state)

      assert result =~ "My Page"
      assert result =~ "hello world"
      # Sources should be tracked (backtick-wrapped slugs)
      assert is_list(new_state.sources)
    end

    test "dran_get_page returns error for unknown slug", %{context: ctx} do
      session = build_session(context_id: ctx.id, meta: %{"context_slug" => ctx.slug})
      state = build_state(session: session)

      {{:error, msg}, _} = Copilot.execute_tool("dran_get_page", %{"slug" => "nope"}, state)
      assert msg =~ "not found"
    end

    test "dran_list_pages returns page listing", %{context: ctx} do
      create_page!(ctx, %{title: "Page A", slug: "page-a"})
      create_page!(ctx, %{title: "Page B", slug: "page-b"})

      session = build_session(context_id: ctx.id, meta: %{"context_slug" => ctx.slug})
      state = build_state(session: session)

      {{:ok, result}, _} = Copilot.execute_tool("dran_list_pages", %{}, state)
      assert result =~ "Page A"
      assert result =~ "Page B"
    end

    test "dran_get_stats returns context statistics", %{context: ctx} do
      create_page!(ctx, %{title: "Stat Page", slug: "stat-page"})

      session = build_session(context_id: ctx.id, meta: %{"context_slug" => ctx.slug})
      state = build_state(session: session)

      {{:ok, result}, _} = Copilot.execute_tool("dran_get_stats", %{}, state)
      assert result =~ "Stats"
    end

    test "unknown tool returns error" do
      state = build_state([])
      {{:error, msg}, _} = Copilot.execute_tool("nonexistent_tool", %{}, state)
      assert msg =~ "unknown tool"
    end

    test "handles nil args gracefully" do
      state = build_state([])
      {{:error, msg}, _} = Copilot.execute_tool("dran_get_page", nil, state)
      assert msg =~ "Error"
    end
  end

  # ── summarize_result/1 ─────────────────────────────────────────────────────

  describe "summarize_result/1" do
    test "summarizes done" do
      assert Copilot.summarize_result({:ok, :done}) == %{status: "done"}
    end

    test "summarizes text result" do
      result = Copilot.summarize_result({:ok, "hello world"})
      assert result.status == "ok"
      assert result.length == 11
      assert result.data == "hello world"
    end

    test "summarizes error with binary reason" do
      result = Copilot.summarize_result({:error, "something failed"})
      assert result.status == "error"
      assert result.error == "something failed"
    end

    test "summarizes error with non-binary reason" do
      result = Copilot.summarize_result({:error, :timeout})
      assert result.status == "error"
      assert result.error == ":timeout"
    end
  end

  # ── gathered_summary/1 ────────────────────────────────────────────────────

  describe "gathered_summary/1" do
    test "returns a string with step and source count" do
      state = build_state(step: 5, sources: ["page-a", "page-b"])
      summary = Copilot.gathered_summary(state)
      assert is_binary(summary)
      assert summary =~ "5"
      assert summary =~ "2"
    end

    test "works with empty sources" do
      state = build_state(step: 0, sources: [])
      summary = Copilot.gathered_summary(state)
      assert is_binary(summary)
      assert summary =~ "0"
    end
  end

  # ── MCP.tool_schemas/0 ────────────────────────────────────────────────────

  describe "MCP.tool_schemas/0" do
    test "returns a list of 18 tool schemas" do
      schemas = MCP.tool_schemas()
      assert is_list(schemas)
      assert length(schemas) == 18
    end

    test "each schema has name, description, and inputSchema" do
      for schema <- MCP.tool_schemas() do
        assert is_binary(schema["name"])
        assert is_binary(schema["description"])
        assert is_map(schema["inputSchema"])
      end
    end

    test "includes dran_search and dran_get_page" do
      names = Enum.map(MCP.tool_schemas(), & &1["name"])
      assert "dran_search" in names
      assert "dran_get_page" in names
    end

    test "dran_search schema has required fields query and context" do
      search = Enum.find(MCP.tool_schemas(), &(&1["name"] == "dran_search"))
      required = search["inputSchema"]["required"]
      assert "query" in required
      assert "context" in required
    end
  end

  # ── run/3 ──────────────────────────────────────────────────────────────────

  describe "run/3" do
    test "is exported with arity 3" do
      assert function_exported?(Copilot, :run, 3)
    end
  end
end
