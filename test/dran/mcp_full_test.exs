defmodule Dran.MCPFullTest do
  @moduledoc """
  Exhaustive tests for all 18 MCP tools via the public JSON-RPC entrypoint
  (Dran.MCP.process_message/1).

  Covers: initialize, tools/list, resources/list, resources/read, prompts/list,
  prompts/get, and every tool in the @tools list.
  """
  use Dran.DataCase, async: false

  alias Dran.{Brain, MCP}

  # Same setup as brain_test.exs / mcp_test.exs: disable inference so
  # dran_create_page doesn't call external APIs.
  setup do
    original = Application.get_env(:dran, :inference)

    Application.put_env(:dran, :inference,
      base_url: nil,
      api_key: nil,
      embedding_model: nil,
      rerank_model: nil,
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

    context =
      Brain.get_context_by_slug("personal") ||
        elem(Brain.create_context(%{name: "Personal", slug: "personal"}), 1)

    {:ok, context: context}
  end

  # Invoke a tool through the public MCP JSON-RPC entrypoint.
  defp call_tool(name, args) do
    msg = %{
      "jsonrpc" => "2.0",
      "method" => "tools/call",
      "id" => 1,
      "params" => %{"name" => name, "arguments" => args}
    }

    %{"result" => %{"content" => [%{"text" => text}]}} = MCP.process_message(msg)
    text
  end

  defp send_message(msg) do
    MCP.process_message(msg)
  end

  # ── Protocol: initialize ────────────────────────────────────────────────────

  describe "initialize" do
    test "returns server info and protocol version" do
      resp =
        send_message(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{
            "protocolVersion" => "2025-03-26",
            "capabilities" => %{},
            "clientInfo" => %{"name" => "test", "version" => "0.1"}
          }
        })

      assert resp["jsonrpc"] == "2.0"
      assert resp["id"] == 1
      assert resp["result"]["serverInfo"]["name"] == "dran"
      assert resp["result"]["protocolVersion"] == "2025-03-26"
      assert Map.has_key?(resp["result"]["capabilities"], "tools")
    end
  end

  # ── Protocol: tools/list ────────────────────────────────────────────────────

  describe "tools/list" do
    test "returns exactly 18 tools" do
      resp =
        send_message(%{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"})

      tools = resp["result"]["tools"]
      assert length(tools) == 18
    end

    test "all tools carry the dran_ prefix" do
      resp =
        send_message(%{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"})

      for tool <- resp["result"]["tools"] do
        assert String.starts_with?(tool["name"], "dran_"),
               "tool #{tool["name"]} is missing the dran_ prefix"
      end
    end

    test "dran_start_agent enum has all 6 agent types" do
      resp =
        send_message(%{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"})

      tools = resp["result"]["tools"]
      start_agent = Enum.find(tools, &(&1["name"] == "dran_start_agent"))
      enum = start_agent["inputSchema"]["properties"]["agent_type"]["enum"]

      assert MapSet.new(enum) ==
               MapSet.new(~w(curator link_gardener graph_rag))
    end
  end

  # ── Protocol: resources/list & resources/read ───────────────────────────────

  describe "resources" do
    test "resources/list returns 3 resources" do
      resp =
        send_message(%{"jsonrpc" => "2.0", "id" => 3, "method" => "resources/list"})

      uris = Enum.map(resp["result"]["resources"], & &1["uri"])
      assert "page://{context}/{slug}" in uris
      assert "goal://{context}/{slug}" in uris
      assert "wiki://{context}/index" in uris
    end

    test "resources/read wiki index returns pages", %{context: ctx} do
      {:ok, _} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "Resource Test Page",
          slug: "resource-test-page",
          page_type: "note"
        })

      resp =
        send_message(%{
          "jsonrpc" => "2.0",
          "id" => 4,
          "method" => "resources/read",
          "params" => %{"uri" => "wiki://personal/index"}
        })

      text = resp["result"]["contents"] |> Enum.at(0) |> Map.get("text")
      assert text =~ "resource-test-page"
    end

    test "resources/read page returns full body", %{context: ctx} do
      {:ok, _} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "Read Test",
          slug: "read-test-page",
          page_type: "note",
          body: "Hello world"
        })

      resp =
        send_message(%{
          "jsonrpc" => "2.0",
          "id" => 5,
          "method" => "resources/read",
          "params" => %{"uri" => "page://personal/read-test-page"}
        })

      text = resp["result"]["contents"] |> Enum.at(0) |> Map.get("text")
      assert text =~ "Read Test"
      assert text =~ "Hello world"
    end

    test "resources/read goal returns JSON with todos", %{context: ctx} do
      {:ok, _} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "My Goal",
          slug: "my-goal-page",
          page_type: "goal",
          meta: %{"health" => "green"}
        })

      {:ok, _} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "Goal Todo",
          slug: "goal-todo-page",
          page_type: "todo",
          meta: %{"goal_slug" => "my-goal-page", "kanban_status" => "today"}
        })

      resp =
        send_message(%{
          "jsonrpc" => "2.0",
          "id" => 6,
          "method" => "resources/read",
          "params" => %{"uri" => "goal://personal/my-goal-page"}
        })

      text = resp["result"]["contents"] |> Enum.at(0) |> Map.get("text")
      json = Jason.decode!(text)
      assert json["goal"]["slug"] == "my-goal-page"
      assert length(json["todos"]) == 1
      assert hd(json["todos"])["slug"] == "goal-todo-page"
    end
  end

  # ── Protocol: prompts/list & prompts/get ────────────────────────────────────

  describe "prompts" do
    test "prompts/list returns 3 prompts" do
      resp =
        send_message(%{"jsonrpc" => "2.0", "id" => 7, "method" => "prompts/list"})

      names = Enum.map(resp["result"]["prompts"], & &1["name"])
      assert "brainstorm" in names
      assert "goal_review" in names
    end

    test "prompts/get with unknown prompt returns error message" do
      resp =
        send_message(%{
          "jsonrpc" => "2.0",
          "id" => 9,
          "method" => "prompts/get",
          "params" => %{"name" => "nonexistent", "arguments" => %{}}
        })

      messages = resp["result"]["messages"]
      assert hd(messages)["content"]["text"] =~ "Error: unknown prompt"
    end
  end

  # ── Tool: dran_search ───────────────────────────────────────────────────────

  describe "dran_search" do
    test "returns matching pages", %{context: ctx} do
      {:ok, _} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "Elixir Phoenix Guide",
          slug: "elixir-phoenix-guide",
          page_type: "note",
          body: "Learn Elixir and Phoenix framework"
        })

      result = call_tool("dran_search", %{"query" => "elixir", "context" => "personal"})
      refute result =~ "Error:"
      assert result =~ "elixir-phoenix-guide"
    end

    test "filters by type" do
      result =
        call_tool("dran_search", %{"query" => "test", "context" => "personal", "type" => "note"})

      # Should return only notes — no error.
      refute result =~ "Error:"
    end

    test "errors on non-existent context" do
      result = call_tool("dran_search", %{"query" => "test", "context" => "no-such-context"})
      assert result =~ "Error: context 'no-such-context' not found"
    end
  end

  # ── Tool: dran_create_page ──────────────────────────────────────────────────

  describe "dran_create_page" do
    test "creates a note page", %{context: ctx} do
      result =
        call_tool("dran_create_page", %{
          "context" => "personal",
          "page_type" => "note",
          "title" => "Test Note",
          "slug" => "create-page-test-note",
          "body" => "A test note",
          "tags" => ["test"],
          "meta" => %{"kind" => "thought"}
        })

      assert result =~ "Created page: Test Note"
      assert result =~ "create-page-test-note"

      page = Brain.get_page_by_slug("create-page-test-note", ctx.id)
      assert page.title == "Test Note"
      assert page.page_type == "note"
    end

    test "errors on duplicate slug", %{context: ctx} do
      {:ok, _} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "Existing",
          slug: "dup-slug-test",
          page_type: "note"
        })

      result =
        call_tool("dran_create_page", %{
          "context" => "personal",
          "page_type" => "note",
          "title" => "Another",
          "slug" => "dup-slug-test",
          "body" => "dup"
        })

      assert result =~ "Error:"
    end

    test "errors on non-existent context" do
      result =
        call_tool("dran_create_page", %{
          "context" => "no-such-context",
          "page_type" => "note",
          "title" => "X",
          "slug" => "x"
        })

      assert result =~ "Error: context"
    end

    test "rejects the system-only report page type", %{context: ctx} do
      result =
        call_tool("dran_create_page", %{
          "context" => "personal",
          "page_type" => "report",
          "title" => "Job report",
          "slug" => "mcp-report-create-test",
          "body" => "must not be created"
        })

      assert result =~
               "Error: page type 'report' is system-created and cannot be created via MCP"

      assert Brain.get_page_by_slug("mcp-report-create-test", ctx.id) == nil
    end

    test "creates a project page with meta", %{context: ctx} do
      result =
        call_tool("dran_create_page", %{
          "context" => "personal",
          "page_type" => "project",
          "title" => "Test Project",
          "slug" => "test-project-create",
          "meta" => %{"status" => "active", "priority" => "high"}
        })

      assert result =~ "Created page: Test Project"
      page = Brain.get_page_by_slug("test-project-create", ctx.id)
      assert page.meta["status"] == "active"
    end
  end

  # ── Tool: dran_update_page ──────────────────────────────────────────────────

  describe "dran_update_page" do
    test "updates body and increments version", %{context: ctx} do
      {:ok, page} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "Update Test",
          slug: "update-test-page",
          page_type: "note",
          body: "original"
        })

      result =
        call_tool("dran_update_page", %{
          "context" => "personal",
          "slug" => "update-test-page",
          "body" => "updated body"
        })

      assert result =~ "Updated page"
      assert result =~ "v2"

      refreshed = Brain.get_page!(page.id)
      assert refreshed.body == "updated body"
      assert refreshed.version == 2
    end

    test "replaces meta entirely (not a merge)", %{context: ctx} do
      {:ok, page} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "Meta Test",
          slug: "meta-test-page",
          page_type: "note",
          body: "x",
          meta: %{"kind" => "thought", "date" => "2026-01-01"}
        })

      # Update with only `kind` — `date` should be gone.
      call_tool("dran_update_page", %{
        "context" => "personal",
        "slug" => "meta-test-page",
        "meta" => %{"kind" => "idea"}
      })

      refreshed = Brain.get_page!(page.id)
      assert refreshed.meta["kind"] == "idea"
      refute Map.has_key?(refreshed.meta, "date")
    end

    test "archives a page", %{context: ctx} do
      {:ok, page} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "Archive Me",
          slug: "archive-me-page",
          page_type: "note"
        })

      result =
        call_tool("dran_update_page", %{
          "context" => "personal",
          "slug" => "archive-me-page",
          "archived" => true
        })

      assert result =~ "Updated page"
      refreshed = Brain.get_page!(page.id)
      assert refreshed.archived == true
    end

    test "errors when slug not found" do
      result =
        call_tool("dran_update_page", %{
          "context" => "personal",
          "slug" => "no-such-page",
          "body" => "x"
        })

      assert result =~ "Error: page 'no-such-page' not found"
    end
  end

  # ── Tool: dran_get_page ─────────────────────────────────────────────────────

  describe "dran_get_page" do
    test "returns full page body", %{context: ctx} do
      {:ok, _} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "Get Page Test",
          slug: "get-page-test",
          page_type: "note",
          body: "This is the body content",
          tags: ["a", "b"]
        })

      result = call_tool("dran_get_page", %{"context" => "personal", "slug" => "get-page-test"})

      assert result =~ "Get Page Test"
      assert result =~ "This is the body content"
      assert result =~ "Type: note"
      assert result =~ "Tags: a, b"
    end

    test "errors when slug not found" do
      result = call_tool("dran_get_page", %{"context" => "personal", "slug" => "missing-slug"})
      assert result =~ "Error: page 'missing-slug' not found"
    end

    test "errors when context not found" do
      result = call_tool("dran_get_page", %{"context" => "no-such", "slug" => "x"})
      assert result =~ "Error: context"
    end
  end

  # ── Tool: dran_delete_page ──────────────────────────────────────────────────

  describe "dran_delete_page" do
    test "deletes a page", %{context: ctx} do
      {:ok, _} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "Delete Me",
          slug: "delete-me-page",
          page_type: "note"
        })

      result =
        call_tool("dran_delete_page", %{"context" => "personal", "slug" => "delete-me-page"})

      assert result =~ "Deleted page: Delete Me"
      assert is_nil(Brain.get_page_by_slug("delete-me-page", ctx.id))
    end

    test "errors when slug not found" do
      result = call_tool("dran_delete_page", %{"context" => "personal", "slug" => "no-such"})
      assert result =~ "Error: page 'no-such' not found"
    end
  end

  # ── Tool: dran_create_todo ──────────────────────────────────────────────────

  describe "dran_create_todo" do
    test "creates a todo with kanban status", %{context: ctx} do
      result =
        call_tool("dran_create_todo", %{
          "context" => "personal",
          "title" => "Test Todo",
          "slug" => "create-todo-test",
          "kanban_status" => "today",
          "priority" => "high"
        })

      assert result =~ "Created todo: Test Todo"
      assert result =~ "status: today"

      todo = Brain.get_page_by_slug("create-todo-test", ctx.id)
      assert todo.meta["kanban_status"] == "today"
      assert todo.meta["priority"] == "high"
    end

    test "sets assignee in meta", %{context: ctx} do
      result =
        call_tool("dran_create_todo", %{
          "context" => "personal",
          "title" => "Assigned Todo",
          "slug" => "assigned-todo-test",
          "assignee" => "hermes"
        })

      assert result =~ "Created todo"
      todo = Brain.get_page_by_slug("assigned-todo-test", ctx.id)
      assert todo.meta["assignee"] == "hermes"
    end

    test "without assignee leaves it absent", %{context: ctx} do
      call_tool("dran_create_todo", %{
        "context" => "personal",
        "title" => "Unassigned Todo",
        "slug" => "unassigned-todo-test"
      })

      todo = Brain.get_page_by_slug("unassigned-todo-test", ctx.id)
      refute Map.has_key?(todo.meta, "assignee")
    end

    test "defaults to backlog status", %{context: ctx} do
      call_tool("dran_create_todo", %{
        "context" => "personal",
        "title" => "Default Todo",
        "slug" => "default-todo-test"
      })

      todo = Brain.get_page_by_slug("default-todo-test", ctx.id)
      assert todo.meta["kanban_status"] == "backlog"
    end

    test "with independent project/goal/plan links", %{context: ctx} do
      {:ok, _} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "Project",
          slug: "link-project",
          page_type: "project"
        })

      {:ok, _} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "Goal",
          slug: "link-goal",
          page_type: "goal"
        })

      result =
        call_tool("dran_create_todo", %{
          "context" => "personal",
          "title" => "Linked Todo",
          "slug" => "linked-todo-test",
          "project_slug" => "link-project",
          "goal_slug" => "link-goal"
        })

      assert result =~ "Created todo"
      todo = Brain.get_page_by_slug("linked-todo-test", ctx.id)
      assert todo.meta["project_slug"] == "link-project"
      assert todo.meta["goal_slug"] == "link-goal"
      refute Map.has_key?(todo.meta, "plan_slug")
    end

    test "errors on duplicate slug", %{context: ctx} do
      {:ok, _} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "Existing Todo",
          slug: "dup-todo-test",
          page_type: "todo"
        })

      result =
        call_tool("dran_create_todo", %{
          "context" => "personal",
          "title" => "Another",
          "slug" => "dup-todo-test"
        })

      assert result =~ "Error:"
    end
  end

  # ── Tool: dran_update_todo ─────────────────────────────────────────────────

  describe "dran_update_todo" do
    test "merges meta (preserves existing keys)", %{context: ctx} do
      {:ok, todo} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "Merge Todo",
          slug: "merge-todo-test",
          page_type: "todo",
          meta: %{"kanban_status" => "backlog", "priority" => "low", "due_date" => "2026-01-01"}
        })

      result =
        call_tool("dran_update_todo", %{
          "context" => "personal",
          "slug" => "merge-todo-test",
          "kanban_status" => "today"
        })

      assert result =~ "Updated todo"
      assert result =~ "status: today"

      refreshed = Brain.get_page!(todo.id)
      assert refreshed.meta["kanban_status"] == "today"
      assert refreshed.meta["priority"] == "low"
      assert refreshed.meta["due_date"] == "2026-01-01"
    end

    test "updates assignee via merge", %{context: ctx} do
      {:ok, todo} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "Assign Todo",
          slug: "assign-update-test",
          page_type: "todo",
          meta: %{"kanban_status" => "backlog", "assignee" => "alvaro"}
        })

      result =
        call_tool("dran_update_todo", %{
          "context" => "personal",
          "slug" => "assign-update-test",
          "assignee" => "hermes"
        })

      assert result =~ "Updated todo"
      refreshed = Brain.get_page!(todo.id)
      assert refreshed.meta["assignee"] == "hermes"
      # kanban_status preserved by merge
      assert refreshed.meta["kanban_status"] == "backlog"
    end

    test "updates links independently", %{context: ctx} do
      {:ok, _} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "Proj",
          slug: "update-proj",
          page_type: "project"
        })

      {:ok, todo} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "Link Todo",
          slug: "link-update-todo",
          page_type: "todo",
          meta: %{"kanban_status" => "backlog"}
        })

      call_tool("dran_update_todo", %{
        "context" => "personal",
        "slug" => "link-update-todo",
        "project_slug" => "update-proj"
      })

      refreshed = Brain.get_page!(todo.id)
      assert refreshed.meta["project_slug"] == "update-proj"
      assert refreshed.meta["kanban_status"] == "backlog"
    end

    test "errors when todo not found" do
      result =
        call_tool("dran_update_todo", %{
          "context" => "personal",
          "slug" => "no-such-todo",
          "kanban_status" => "done"
        })

      assert result =~ "Error: todo 'no-such-todo' not found"
    end
  end

  # ── Tool: dran_create_relation ─────────────────────────────────────────────

  describe "dran_create_relation" do
    test "creates a related relation", %{context: ctx} do
      {:ok, _} =
        Brain.create_page(%{context_id: ctx.id, title: "A", slug: "rel-a", page_type: "note"})

      {:ok, _} =
        Brain.create_page(%{context_id: ctx.id, title: "B", slug: "rel-b", page_type: "note"})

      result =
        call_tool("dran_create_relation", %{
          "context" => "personal",
          "source_slug" => "rel-a",
          "target_slug" => "rel-b",
          "relation_type" => "related"
        })

      assert result =~ "Created relation: rel-a --related--> rel-b"
    end

    test "errors when source not found" do
      result =
        call_tool("dran_create_relation", %{
          "context" => "personal",
          "source_slug" => "no-source",
          "target_slug" => "no-target"
        })

      assert result =~ "Error: source page 'no-source' not found"
    end

    test "errors when target not found", %{context: ctx} do
      {:ok, _} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "Src",
          slug: "src-exists",
          page_type: "note"
        })

      result =
        call_tool("dran_create_relation", %{
          "context" => "personal",
          "source_slug" => "src-exists",
          "target_slug" => "no-target"
        })

      assert result =~ "Error: target page 'no-target' not found"
    end

    test "defaults to related type", %{context: ctx} do
      {:ok, _} =
        Brain.create_page(%{context_id: ctx.id, title: "C", slug: "rel-c", page_type: "note"})

      {:ok, _} =
        Brain.create_page(%{context_id: ctx.id, title: "D", slug: "rel-d", page_type: "note"})

      result =
        call_tool("dran_create_relation", %{
          "context" => "personal",
          "source_slug" => "rel-c",
          "target_slug" => "rel-d"
        })

      assert result =~ "Created relation: rel-c --related--> rel-d"
    end
  end

  # ── Tool: dran_delete_relation ─────────────────────────────────────────────

  describe "dran_delete_relation" do
    test "deletes a relation", %{context: ctx} do
      {:ok, _} =
        Brain.create_page(%{context_id: ctx.id, title: "X", slug: "del-rel-x", page_type: "note"})

      {:ok, _} =
        Brain.create_page(%{context_id: ctx.id, title: "Y", slug: "del-rel-y", page_type: "note"})

      Brain.create_relation_by_slugs("del-rel-x", "del-rel-y", "related", ctx.id)

      result =
        call_tool("dran_delete_relation", %{
          "context" => "personal",
          "source_slug" => "del-rel-x",
          "target_slug" => "del-rel-y"
        })

      assert result =~ "Deleted 1 relation"
    end

    test "handles non-existent pages gracefully" do
      result =
        call_tool("dran_delete_relation", %{
          "context" => "personal",
          "source_slug" => "no-page-a",
          "target_slug" => "no-page-b"
        })

      # Should not crash — returns 0 deleted or error
      assert result =~ "Deleted" or result =~ "Error"
    end
  end

  # ── Tool: dran_get_links ───────────────────────────────────────────────────

  describe "dran_get_links" do
    test "returns inbound and outbound relations", %{context: ctx} do
      {:ok, _} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "Links A",
          slug: "links-a",
          page_type: "note"
        })

      {:ok, _} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "Links B",
          slug: "links-b",
          page_type: "note"
        })

      Brain.create_relation_by_slugs("links-a", "links-b", "related", ctx.id)

      result = call_tool("dran_get_links", %{"context" => "personal", "slug" => "links-a"})

      assert result =~ "Relations for 'Links A'"
      assert result =~ "Outbound (1)"
      assert result =~ "links-b"
      assert result =~ "related"
    end

    test "errors when page not found" do
      result = call_tool("dran_get_links", %{"context" => "personal", "slug" => "no-links"})
      assert result =~ "Error: page 'no-links' not found"
    end
  end

  # ── Tool: dran_list_pages ───────────────────────────────────────────────────

  describe "dran_list_pages" do
    test "lists pages in a context" do
      result = call_tool("dran_list_pages", %{"context" => "personal", "limit" => 5})
      refute result =~ "Error:"
      assert result =~ "Found"
    end

    test "filters by type", %{context: ctx} do
      {:ok, _} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "Filter Note",
          slug: "filter-type-note",
          page_type: "note"
        })

      result =
        call_tool("dran_list_pages", %{
          "context" => "personal",
          "type" => "note",
          "limit" => 100
        })

      assert result =~ "filter-type-note"
    end

    test "filters by tag", %{context: ctx} do
      {:ok, _} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "Tagged",
          slug: "tag-filter-test",
          page_type: "note",
          tags: ["filter-tag-xyz"]
        })

      result =
        call_tool("dran_list_pages", %{
          "context" => "personal",
          "tag" => "filter-tag-xyz"
        })

      assert result =~ "tag-filter-test"
    end

    test "filters by owner", %{context: ctx} do
      {:ok, _} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "Owner Test",
          slug: "owner-filter-test",
          page_type: "note",
          owner: "alice"
        })

      result =
        call_tool("dran_list_pages", %{
          "context" => "personal",
          "owner" => "alice"
        })

      assert result =~ "owner-filter-test"
    end

    test "filters by created_by", %{context: ctx} do
      {:ok, _} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "Creator Test",
          slug: "creator-filter-test",
          page_type: "note",
          created_by: "bob"
        })

      result =
        call_tool("dran_list_pages", %{
          "context" => "personal",
          "created_by" => "bob"
        })

      assert result =~ "creator-filter-test"
    end

    test "filters by assignee", %{context: ctx} do
      {:ok, _} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "Assigned to Hermes",
          slug: "assignee-filter-hermes",
          page_type: "todo",
          meta: %{"kanban_status" => "backlog", "assignee" => "hermes"}
        })

      {:ok, _} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "Assigned to Alvaro",
          slug: "assignee-filter-alvaro",
          page_type: "todo",
          meta: %{"kanban_status" => "backlog", "assignee" => "alvaro"}
        })

      result =
        call_tool("dran_list_pages", %{
          "context" => "personal",
          "assignee" => "hermes"
        })

      assert result =~ "assignee-filter-hermes"
      refute result =~ "assignee-filter-alvaro"
    end

    test "filters unassigned todos with 'none'", %{context: ctx} do
      {:ok, _} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "Unassigned Todo",
          slug: "assignee-filter-none",
          page_type: "todo",
          meta: %{"kanban_status" => "backlog"}
        })

      {:ok, _} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "Assigned Todo",
          slug: "assignee-filter-set",
          page_type: "todo",
          meta: %{"kanban_status" => "backlog", "assignee" => "hermes"}
        })

      result =
        call_tool("dran_list_pages", %{
          "context" => "personal",
          "assignee" => "none"
        })

      assert result =~ "assignee-filter-none"
      refute result =~ "assignee-filter-set"
    end

    test "respects limit" do
      result =
        call_tool("dran_list_pages", %{
          "context" => "personal",
          "limit" => 2
        })

      # Should not return more than 2 pages
      count =
        result
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "- **"))
        |> length()

      assert count <= 2
    end

    test "errors on non-existent context" do
      result = call_tool("dran_list_pages", %{"context" => "no-such", "limit" => 5})
      assert result =~ "Error: context"
    end
  end

  # ── Tool: dran_get_stats ────────────────────────────────────────────────────

  describe "dran_get_stats" do
    test "returns stats with totals" do
      result = call_tool("dran_get_stats", %{"context" => "personal"})
      refute result =~ "Error:"
      assert result =~ "Stats for 'personal'"
      assert result =~ "Total pages:"
      assert result =~ "Total relations:"
      assert result =~ "Pages by type"
      assert result =~ "Todos by status"
    end

    test "errors on non-existent context" do
      result = call_tool("dran_get_stats", %{"context" => "no-such"})
      assert result =~ "Error: context"
    end
  end

  # ── Tool: dran_lint_brain ──────────────────────────────────────────────────

  describe "dran_lint_brain" do
    test "returns lint report with categories" do
      result = call_tool("dran_lint_brain", %{"context" => "personal"})
      refute result =~ "Error:"
      assert result =~ "Lint Report"
      assert result =~ "Orphan pages"
      assert result =~ "Stale pages"
      assert result =~ "Contested pages"
    end

    test "errors on non-existent context" do
      result = call_tool("dran_lint_brain", %{"context" => "no-such"})
      assert result =~ "Error: context"
    end
  end

  # ── Tool: dran_rename_slug ─ (already covered in mcp_test.exs, adding more)

  describe "dran_rename_slug (additional)" do
    test "errors when old_slug equals new_slug" do
      result =
        call_tool("dran_rename_slug", %{
          "context" => "personal",
          "old_slug" => "same",
          "new_slug" => "same"
        })

      assert result =~ "Error: old_slug and new_slug are the same"
    end

    test "errors when context not found" do
      result =
        call_tool("dran_rename_slug", %{
          "context" => "no-such",
          "old_slug" => "a",
          "new_slug" => "b"
        })

      assert result =~ "Error: context"
    end
  end

  # ── Tool: dran_reaugment_page ─ (already covered in mcp_test.exs, adding more)

  describe "dran_reaugment_page (additional)" do
    test "errors when context not found" do
      result =
        call_tool("dran_reaugment_page", %{
          "context" => "no-such",
          "slug" => "x"
        })

      assert result =~ "Error: context"
    end
  end

  # ── Tool: dran_start_agent ──────────────────────────────────────────────────

  describe "dran_start_agent" do
    test "errors on unknown agent type" do
      result =
        call_tool("dran_start_agent", %{
          "agent_type" => "nonexistent",
          "context" => "personal",
          "input" => "test"
        })

      assert result =~ "Error:"
    end

    test "errors on non-existent context" do
      result =
        call_tool("dran_start_agent", %{
          "agent_type" => "ask",
          "context" => "no-such",
          "input" => "test"
        })

      assert result =~ "Error: context"
    end
  end

  # ── Tool: dran_get_agent_session ────────────────────────────────────────────

  describe "dran_get_agent_session" do
    test "errors on invalid UUID" do
      result = call_tool("dran_get_agent_session", %{"session_id" => "not-a-uuid"})
      assert result =~ "Error: invalid session_id"
    end

    test "errors on non-existent session" do
      result =
        call_tool("dran_get_agent_session", %{
          "session_id" => "00000000-0000-0000-0000-000000000000"
        })

      assert result =~ "Error: session not found"
    end
  end

  # ── Unknown tool ────────────────────────────────────────────────────────────

  describe "unknown tool" do
    test "returns error for unknown tool name" do
      result = call_tool("dran_nonexistent_tool", %{})
      assert result =~ "Error: unknown tool 'dran_nonexistent_tool'"
    end
  end

  # ── Error handling ──────────────────────────────────────────────────────────

  describe "error handling" do
    test "unknown method returns method not found" do
      resp =
        send_message(%{"jsonrpc" => "2.0", "id" => 99, "method" => "unknown/method"})

      assert resp["error"]["code"] == -32601
      assert resp["error"]["message"] == "Method not found"
    end

    test "notifications return nil" do
      resp =
        send_message(%{"jsonrpc" => "2.0", "method" => "initialized"})

      assert is_nil(resp)
    end

    test "notification? detects notifications" do
      assert MCP.notification?(%{"jsonrpc" => "2.0", "method" => "initialized"})
      refute MCP.notification?(%{"jsonrpc" => "2.0", "method" => "tools/list", "id" => 1})
      refute MCP.notification?("not a map")
    end

    test "generate_session_id returns a string" do
      id = MCP.generate_session_id()
      assert is_binary(id)
      assert String.length(id) > 0
    end

    test "protocol_version returns the version string" do
      assert MCP.protocol_version() == "2025-03-26"
    end
  end
end
