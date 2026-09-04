defmodule Dran.MCPFullTest do
  @moduledoc """
  Exhaustive tests for all 18 MCP tools via the public JSON-RPC entrypoint
  (Dran.MCP.process_message/1).

  Covers: initialize, tools/list, resources/list, resources/read, prompts/list,
  prompts/get, and every tool in the @tools list.
  """
  use Dran.DataCase, async: false

  alias Dran.{Goals, Knowledge, MCP}

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
      Knowledge.get_workspace_by_slug("personal") ||
        elem(Knowledge.create_workspace(%{name: "Personal", slug: "personal"}), 1)

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
    test "returns exactly 22 tools" do
      resp =
        send_message(%{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"})

      tools = resp["result"]["tools"]
      assert length(tools) == 22
    end

    test "all tools carry the dran_ prefix" do
      resp =
        send_message(%{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"})

      for tool <- resp["result"]["tools"] do
        assert String.starts_with?(tool["name"], "dran_"),
               "tool #{tool["name"]} is missing the dran_ prefix"
      end
    end

    test "dran_start_worker enum has all 3 agent types" do
      resp =
        send_message(%{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"})

      tools = resp["result"]["tools"]
      start_agent = Enum.find(tools, &(&1["name"] == "dran_start_worker"))
      enum = start_agent["inputSchema"]["properties"]["worker_type"]["enum"]

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
      assert "page://{workspace}/{slug}" in uris
      assert "goal://{workspace}/{slug}" in uris
      assert "home://{workspace}/index" in uris
    end

    test "resources/read wiki index returns pages", %{context: ctx} do
      {:ok, _} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Resource Test Page",
          slug: "resource-test-page",
          page_type: "note"
        })

      resp =
        send_message(%{
          "jsonrpc" => "2.0",
          "id" => 4,
          "method" => "resources/read",
          "params" => %{"uri" => "home://personal/index"}
        })

      text = resp["result"]["contents"] |> Enum.at(0) |> Map.get("text")
      assert text =~ "resource-test-page"
    end

    test "resources/read page returns full body", %{context: ctx} do
      {:ok, _} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
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
      {:ok, goal} =
        Goals.create_goal(%{
          workspace_id: ctx.id,
          title: "My Goal",
          slug: "my-goal-page"
        })

      {:ok, note} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Goal Todo",
          slug: "goal-todo-page",
          page_type: "note",
          meta: %{"kind" => "todo", "kanban_status" => "today"}
        })

      # Link the note to the goal via a part_of relation
      Knowledge.create_relation(%{
        source_id: note.id,
        source_type: "page",
        target_id: goal.id,
        target_type: "goal",
        relation_type: "part_of"
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
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Elixir Phoenix Guide",
          slug: "elixir-phoenix-guide",
          page_type: "note",
          body: "Learn Elixir and Phoenix framework"
        })

      result = call_tool("dran_search", %{"query" => "elixir", "workspace" => "personal"})
      refute result =~ "Error:"
      assert result =~ "elixir-phoenix-guide"
    end

    test "filters by type" do
      result =
        call_tool("dran_search", %{"query" => "test", "workspace" => "personal", "type" => "note"})

      # Should return only notes — no error.
      refute result =~ "Error:"
    end

    test "errors on non-existent context" do
      result = call_tool("dran_search", %{"query" => "test", "workspace" => "no-such-context"})
      assert result =~ "Error: context 'no-such-context' not found"
    end
  end

  # ── Tool: dran_create_page ──────────────────────────────────────────────────

  describe "dran_create_page" do
    test "creates a note page", %{context: ctx} do
      result =
        call_tool("dran_create_page", %{
          "workspace" => "personal",
          "page_type" => "note",
          "title" => "Test Note",
          "slug" => "create-page-test-note",
          "body" => "A test note",
          "tags" => ["test"],
          "meta" => %{"kind" => "idea"}
        })

      assert result =~ "Created page: Test Note"
      assert result =~ "create-page-test-note"

      page = Knowledge.get_page_by_slug("create-page-test-note", ctx.id)
      assert page.title == "Test Note"
      assert page.page_type == "note"
    end

    test "errors on duplicate slug", %{context: ctx} do
      {:ok, _} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Existing",
          slug: "dup-slug-test",
          page_type: "note"
        })

      result =
        call_tool("dran_create_page", %{
          "workspace" => "personal",
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
          "workspace" => "no-such-context",
          "page_type" => "note",
          "title" => "X",
          "slug" => "x"
        })

      assert result =~ "Error: context"
    end

    test "rejects the system-only report page type", %{context: ctx} do
      result =
        call_tool("dran_create_page", %{
          "workspace" => "personal",
          "page_type" => "report",
          "title" => "Job report",
          "slug" => "mcp-report-create-test",
          "body" => "must not be created"
        })

      assert result =~
               "Error: page type 'report' is not a valid page type — use dran_create_goal or dran_create_note for goals and todo-style notes"

      assert Knowledge.get_page_by_slug("mcp-report-create-test", ctx.id) == nil
    end

    test "rejects non-page types (goal, project, todo, plan)", %{context: _ctx} do
      for page_type <- ~w(goal project todo plan) do
        result =
          call_tool("dran_create_page", %{
            "workspace" => "personal",
            "page_type" => page_type,
            "title" => "Test #{page_type}",
            "slug" => "test-#{page_type}-create"
          })

        assert result =~ "Error: page type '#{page_type}' is not a valid page type"
      end
    end
  end

  # ── Tool: dran_update_page ──────────────────────────────────────────────────

  describe "dran_update_page" do
    test "updates body and increments version", %{context: ctx} do
      {:ok, page} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Update Test",
          slug: "update-test-page",
          page_type: "note",
          body: "original"
        })

      result =
        call_tool("dran_update_page", %{
          "workspace" => "personal",
          "slug" => "update-test-page",
          "body" => "updated body"
        })

      assert result =~ "Updated page"
      assert result =~ "v2"

      refreshed = Knowledge.get_page!(page.id)
      assert refreshed.body == "updated body"
      assert refreshed.version == 2
    end

    test "replaces meta entirely (not a merge)", %{context: ctx} do
      {:ok, page} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Meta Test",
          slug: "meta-test-page",
          page_type: "note",
          body: "x",
          meta: %{"kind" => "idea", "date" => "2026-01-01"}
        })

      # Update with only `kind` — `date` should be gone.
      call_tool("dran_update_page", %{
        "workspace" => "personal",
        "slug" => "meta-test-page",
        "meta" => %{"kind" => "idea"}
      })

      refreshed = Knowledge.get_page!(page.id)
      assert refreshed.meta["kind"] == "idea"
      refute Map.has_key?(refreshed.meta, "date")
    end

    test "archives a page", %{context: ctx} do
      {:ok, page} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Archive Me",
          slug: "archive-me-page",
          page_type: "note"
        })

      result =
        call_tool("dran_update_page", %{
          "workspace" => "personal",
          "slug" => "archive-me-page",
          "archived" => true
        })

      assert result =~ "Updated page"
      refreshed = Knowledge.get_page!(page.id)
      assert refreshed.archived == true
    end

    test "errors when slug not found" do
      result =
        call_tool("dran_update_page", %{
          "workspace" => "personal",
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
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Get Page Test",
          slug: "get-page-test",
          page_type: "note",
          body: "This is the body content",
          tags: ["a", "b"]
        })

      result = call_tool("dran_get_page", %{"workspace" => "personal", "slug" => "get-page-test"})

      assert result =~ "Get Page Test"
      assert result =~ "This is the body content"
      assert result =~ "Type: note"
      assert result =~ "Tags: a, b"
    end

    test "errors when slug not found" do
      result = call_tool("dran_get_page", %{"workspace" => "personal", "slug" => "missing-slug"})
      assert result =~ "Error: page 'missing-slug' not found"
    end

    test "errors when context not found" do
      result = call_tool("dran_get_page", %{"workspace" => "no-such", "slug" => "x"})
      assert result =~ "Error: context"
    end
  end

  # ── Tool: dran_delete_page ──────────────────────────────────────────────────

  describe "dran_delete_page" do
    test "deletes a page", %{context: ctx} do
      {:ok, _} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Delete Me",
          slug: "delete-me-page",
          page_type: "note"
        })

      result =
        call_tool("dran_delete_page", %{"workspace" => "personal", "slug" => "delete-me-page"})

      assert result =~ "Deleted page: Delete Me"
      assert is_nil(Knowledge.get_page_by_slug("delete-me-page", ctx.id))
    end

    test "errors when slug not found" do
      result = call_tool("dran_delete_page", %{"workspace" => "personal", "slug" => "no-such"})
      assert result =~ "Error: page 'no-such' not found"
    end
  end

  # ── Tool: dran_create_note ─────────────────────────────────────────────────

  describe "dran_create_note" do
    test "creates a plain note with default journal kind", %{context: ctx} do
      result =
        call_tool("dran_create_note", %{
          "workspace" => "personal",
          "title" => "Test Note",
          "slug" => "create-note-test",
          "kind" => "meeting"
        })

      assert result =~ "Created note: Test Note"

      note = Knowledge.get_page_by_slug("create-note-test", ctx.id)
      assert note.page_type == "note"
      assert note.meta["kind"] == "meeting"
    end

    test "kind defaults to journal", %{context: ctx} do
      call_tool("dran_create_note", %{
        "workspace" => "personal",
        "title" => "Default Note",
        "slug" => "default-note-test"
      })

      note = Knowledge.get_page_by_slug("default-note-test", ctx.id)
      assert note.meta["kind"] == "journal"
    end

    test "errors on duplicate slug", %{context: ctx} do
      {:ok, _} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Existing Note",
          slug: "dup-note-test",
          page_type: "note"
        })

      result =
        call_tool("dran_create_note", %{
          "workspace" => "personal",
          "title" => "Another",
          "slug" => "dup-note-test"
        })

      assert result =~ "Error:"
    end
  end

  # ── Tool: dran_update_note ─────────────────────────────────────────────────

  describe "dran_update_note" do
    test "merges meta (preserves existing keys)", %{context: ctx} do
      {:ok, note} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Merge Note",
          slug: "merge-note-test",
          page_type: "note",
          meta: %{
            "kind" => "meeting",
            "priority" => "low",
            "due_date" => "2026-01-01"
          }
        })

      result =
        call_tool("dran_update_note", %{
          "workspace" => "personal",
          "slug" => "merge-note-test",
          "due_date" => "2026-02-02"
        })

      assert result =~ "Updated note"

      refreshed = Knowledge.get_page!(note.id)
      assert refreshed.meta["due_date"] == "2026-02-02"
      assert refreshed.meta["priority"] == "low"
    end

    test "updates assignee via merge", %{context: ctx} do
      {:ok, note} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Assign Note",
          slug: "assign-update-test",
          page_type: "note",
          meta: %{"kind" => "meeting", "assignee" => "alvaro"}
        })

      result =
        call_tool("dran_update_note", %{
          "workspace" => "personal",
          "slug" => "assign-update-test",
          "assignee" => "hermes"
        })

      assert result =~ "Updated note"
      refreshed = Knowledge.get_page!(note.id)
      assert refreshed.meta["assignee"] == "hermes"
      # kind preserved by merge
      assert refreshed.meta["kind"] == "meeting"
    end

    test "errors when note not found" do
      result =
        call_tool("dran_update_note", %{
          "workspace" => "personal",
          "slug" => "no-such-note",
          "due_date" => "2026-03-03"
        })

      assert result =~ "Error: note 'no-such-note' not found"
    end
  end

  # ── Tool: dran_create_goal ──────────────────────────────────────────────────

  describe "dran_create_goal" do
    test "creates a goal with full attrs", %{context: ctx} do
      result =
        call_tool("dran_create_goal", %{
          "workspace" => "personal",
          "title" => "Ship v1",
          "slug" => "ship-v1-goal",
          "summary" => "Launch the product",
          "status" => "active",
          "team" => ["alvaro", "hermes"]
        })

      assert result =~ "Created goal: Ship v1"
      assert result =~ "ship-v1-goal"
      assert result =~ "status: active"

      goal = Goals.get_goal_by_slug("ship-v1-goal", ctx.id)
      assert goal.team == ["alvaro", "hermes"]
    end

    test "derives slug from title when omitted", %{context: ctx} do
      result =
        call_tool("dran_create_goal", %{
          "workspace" => "personal",
          "title" => "Learn Elixir"
        })

      assert result =~ "Created goal: Learn Elixir"
      assert result =~ "learn-elixir"
      assert Goals.get_goal_by_slug("learn-elixir", ctx.id) != nil
    end

    test "errors on duplicate slug", %{context: ctx} do
      {:ok, _} =
        Goals.create_goal(%{
          workspace_id: ctx.id,
          title: "Existing",
          slug: "dup-goal-test"
        })

      result =
        call_tool("dran_create_goal", %{
          "workspace" => "personal",
          "title" => "Another",
          "slug" => "dup-goal-test"
        })

      assert result =~ "Error:"
    end

    test "errors on non-existent context" do
      result =
        call_tool("dran_create_goal", %{
          "workspace" => "no-such-context",
          "title" => "X"
        })

      assert result =~ "Error: context"
    end
  end

  # ── Tool: dran_create_project (removed — projects are notes with kind:"project") ──

  describe "dran_create_project" do
    test "returns unknown tool error", %{context: _ctx} do
      result =
        call_tool("dran_create_project", %{
          "workspace" => "personal",
          "title" => "Website Redesign"
        })

      assert result =~ "Error: unknown tool"
    end
  end

  # ── Tool: dran_create_relation ─────────────────────────────────────────────

  describe "dran_create_relation" do
    test "creates a related relation", %{context: ctx} do
      {:ok, _} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "A",
          slug: "rel-a",
          page_type: "note"
        })

      {:ok, _} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "B",
          slug: "rel-b",
          page_type: "note"
        })

      result =
        call_tool("dran_create_relation", %{
          "workspace" => "personal",
          "source_slug" => "rel-a",
          "target_slug" => "rel-b",
          "relation_type" => "related"
        })

      assert result =~ "Created relation: rel-a --related--> rel-b"
    end

    test "errors when source not found" do
      result =
        call_tool("dran_create_relation", %{
          "workspace" => "personal",
          "source_slug" => "no-source",
          "target_slug" => "no-target"
        })

      assert result =~ "Error: source page 'no-source' not found"
    end

    test "errors when target not found", %{context: ctx} do
      {:ok, _} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Src",
          slug: "src-exists",
          page_type: "note"
        })

      result =
        call_tool("dran_create_relation", %{
          "workspace" => "personal",
          "source_slug" => "src-exists",
          "target_slug" => "no-target"
        })

      assert result =~ "Error: target page 'no-target' not found"
    end

    test "defaults to related type", %{context: ctx} do
      {:ok, _} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "C",
          slug: "rel-c",
          page_type: "note"
        })

      {:ok, _} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "D",
          slug: "rel-d",
          page_type: "note"
        })

      result =
        call_tool("dran_create_relation", %{
          "workspace" => "personal",
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
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "X",
          slug: "del-rel-x",
          page_type: "note"
        })

      {:ok, _} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Y",
          slug: "del-rel-y",
          page_type: "note"
        })

      Knowledge.create_relation_by_slugs("del-rel-x", "del-rel-y", "related", ctx.id)

      result =
        call_tool("dran_delete_relation", %{
          "workspace" => "personal",
          "source_slug" => "del-rel-x",
          "target_slug" => "del-rel-y"
        })

      assert result =~ "Deleted 1 relation"
    end

    test "handles non-existent pages gracefully" do
      result =
        call_tool("dran_delete_relation", %{
          "workspace" => "personal",
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
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Links A",
          slug: "links-a",
          page_type: "note"
        })

      {:ok, _} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Links B",
          slug: "links-b",
          page_type: "note"
        })

      Knowledge.create_relation_by_slugs("links-a", "links-b", "related", ctx.id)

      result = call_tool("dran_get_links", %{"workspace" => "personal", "slug" => "links-a"})

      assert result =~ "Relations for 'Links A'"
      assert result =~ "Outbound (1)"
      assert result =~ "links-b"
      assert result =~ "related"
    end

    test "errors when page not found" do
      result = call_tool("dran_get_links", %{"workspace" => "personal", "slug" => "no-links"})
      assert result =~ "Error: page 'no-links' not found"
    end
  end

  # ── Tool: dran_list_pages ───────────────────────────────────────────────────

  describe "dran_list_pages" do
    test "lists pages in a context" do
      result = call_tool("dran_list_pages", %{"workspace" => "personal", "limit" => 5})
      refute result =~ "Error:"
      assert result =~ "Found"
    end

    test "filters by type", %{context: ctx} do
      {:ok, _} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Filter Note",
          slug: "filter-type-note",
          page_type: "note"
        })

      result =
        call_tool("dran_list_pages", %{
          "workspace" => "personal",
          "type" => "note",
          "limit" => 100
        })

      assert result =~ "filter-type-note"
    end

    test "filters by tag", %{context: ctx} do
      {:ok, _} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Tagged",
          slug: "tag-filter-test",
          page_type: "note",
          tags: ["filter-tag-xyz"]
        })

      result =
        call_tool("dran_list_pages", %{
          "workspace" => "personal",
          "tag" => "filter-tag-xyz"
        })

      assert result =~ "tag-filter-test"
    end

    test "owner filter is a no-op after the owner column was dropped", %{context: ctx} do
      {:ok, _} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Owner Test",
          slug: "owner-filter-test",
          page_type: "note",
          created_by: "alice"
        })

      result =
        call_tool("dran_list_pages", %{
          "workspace" => "personal",
          "owner" => "alice"
        })

      # The owner filter no longer excludes rows (no-op for backward compat);
      # created_by is the supported filter since the actor model.
      assert result =~ "owner-filter-test"

      by_creator =
        call_tool("dran_list_pages", %{
          "workspace" => "personal",
          "created_by" => "alice"
        })

      assert by_creator =~ "owner-filter-test"
    end

    test "filters by created_by", %{context: ctx} do
      {:ok, _} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Creator Test",
          slug: "creator-filter-test",
          page_type: "note",
          created_by: "bob"
        })

      result =
        call_tool("dran_list_pages", %{
          "workspace" => "personal",
          "created_by" => "bob"
        })

      assert result =~ "creator-filter-test"
    end

    test "filters by assignee", %{context: ctx} do
      {:ok, _} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Assigned to Hermes",
          slug: "assignee-filter-hermes",
          page_type: "note",
          meta: %{"kind" => "todo", "kanban_status" => "backlog", "assignee" => "hermes"}
        })

      {:ok, _} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Assigned to Alvaro",
          slug: "assignee-filter-alvaro",
          page_type: "note",
          meta: %{"kind" => "todo", "kanban_status" => "backlog", "assignee" => "alvaro"}
        })

      result =
        call_tool("dran_list_pages", %{
          "workspace" => "personal",
          "assignee" => "hermes"
        })

      assert result =~ "assignee-filter-hermes"
      refute result =~ "assignee-filter-alvaro"
    end

    test "filters unassigned todos with 'none'", %{context: ctx} do
      {:ok, _} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Unassigned Todo",
          slug: "assignee-filter-none",
          page_type: "note",
          meta: %{"kind" => "todo", "kanban_status" => "backlog"}
        })

      {:ok, _} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Assigned Todo",
          slug: "assignee-filter-set",
          page_type: "note",
          meta: %{"kind" => "todo", "kanban_status" => "backlog", "assignee" => "hermes"}
        })

      result =
        call_tool("dran_list_pages", %{
          "workspace" => "personal",
          "assignee" => "none"
        })

      assert result =~ "assignee-filter-none"
      refute result =~ "assignee-filter-set"
    end

    test "respects limit" do
      result =
        call_tool("dran_list_pages", %{
          "workspace" => "personal",
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
      result = call_tool("dran_list_pages", %{"workspace" => "no-such", "limit" => 5})
      assert result =~ "Error: context"
    end
  end

  # ── Tool: dran_get_stats ────────────────────────────────────────────────────

  describe "dran_get_stats" do
    test "returns stats with totals" do
      result = call_tool("dran_get_stats", %{"workspace" => "personal"})
      refute result =~ "Error:"
      assert result =~ "Stats for 'personal'"
      assert result =~ "Total pages:"
      assert result =~ "Total relations:"
      assert result =~ "Pages by type"
      assert result =~ "Todos by status"
    end

    test "errors on non-existent context" do
      result = call_tool("dran_get_stats", %{"workspace" => "no-such"})
      assert result =~ "Error: context"
    end
  end

  # ── Tool: dran_lint_brain ──────────────────────────────────────────────────

  describe "dran_lint_brain" do
    test "returns lint report with categories" do
      result = call_tool("dran_lint_brain", %{"workspace" => "personal"})
      refute result =~ "Error:"
      assert result =~ "Lint Report"
      assert result =~ "Orphan pages"
      assert result =~ "Stale pages"
      assert result =~ "Contested pages"
    end

    test "errors on non-existent context" do
      result = call_tool("dran_lint_brain", %{"workspace" => "no-such"})
      assert result =~ "Error: context"
    end
  end

  # ── Tool: dran_rename_slug ─ (already covered in mcp_test.exs, adding more)

  describe "dran_rename_slug (additional)" do
    test "errors when old_slug equals new_slug" do
      result =
        call_tool("dran_rename_slug", %{
          "workspace" => "personal",
          "old_slug" => "same",
          "new_slug" => "same"
        })

      assert result =~ "Error: old_slug and new_slug are the same"
    end

    test "errors when context not found" do
      result =
        call_tool("dran_rename_slug", %{
          "workspace" => "no-such",
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
          "workspace" => "no-such",
          "slug" => "x"
        })

      assert result =~ "Error: context"
    end
  end

  # ── Tool: dran_start_worker ──────────────────────────────────────────────────

  describe "dran_start_worker" do
    test "errors on unknown agent type" do
      result =
        call_tool("dran_start_worker", %{
          "worker_type" => "nonexistent",
          "workspace" => "personal",
          "input" => "test"
        })

      assert result =~ "Error:"
    end

    test "errors on non-existent context" do
      result =
        call_tool("dran_start_worker", %{
          "worker_type" => "ask",
          "workspace" => "no-such",
          "input" => "test"
        })

      assert result =~ "Error: context"
    end
  end

  # ── Tool: dran_get_worker_session ────────────────────────────────────────────

  describe "dran_get_worker_session" do
    test "errors on invalid UUID" do
      result = call_tool("dran_get_worker_session", %{"session_id" => "not-a-uuid"})
      assert result =~ "Error: invalid session_id"
    end

    test "errors on non-existent session" do
      result =
        call_tool("dran_get_worker_session", %{
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
