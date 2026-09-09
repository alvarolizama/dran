defmodule Dran.MCPFullTest do
  @moduledoc """
  Exhaustive tests for all 18 MCP tools via the public JSON-RPC entrypoint
  (Dran.MCP.process_message/1).

  Covers: initialize, tools/list, resources/list, resources/read, prompts/list,
  prompts/get, and every tool in the @tools list.
  """
  use Dran.DataCase, async: false

  alias Dran.{Contracts, Executions, Goals, Knowledge, MCP, Workflows}

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

  # "Created workflow: Title (slug) — ..." → slug
  defp extract_slug(result) do
    [_, slug] = Regex.run(~r/\(([^)]+)\)/, result)
    slug
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
    test "returns exactly 19 tools" do
      resp =
        send_message(%{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"})

      tools = resp["result"]["tools"]
      assert length(tools) == 36
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

    test "resources/read goal returns JSON with linked notes", %{context: ctx} do
      {:ok, goal} =
        Goals.create_goal(%{
          workspace_id: ctx.id,
          title: "My Goal",
          slug: "my-goal-page"
        })

      {:ok, note} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Goal Note",
          slug: "goal-note-page",
          page_type: "note",
          meta: %{"kind" => "idea"}
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
      assert length(json["notes"]) == 1
      assert hd(json["notes"])["slug"] == "goal-note-page"
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
               "Error: page type 'report' is not a valid page type — use dran_create_goal for goals"

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
      assert refreshed.meta["kind"] == "meeting"
    end

    test "rejects legacy kanban keys on notes", %{context: ctx} do
      {:ok, note} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Assign Note",
          slug: "assign-update-test",
          page_type: "note",
          meta: %{"kind" => "meeting"}
        })

      result =
        call_tool("dran_update_note", %{
          "workspace" => "personal",
          "slug" => "assign-update-test",
          "assignee" => "hermes"
        })

      assert result =~ "Error:"
      refreshed = Knowledge.get_page!(note.id)
      refute Map.has_key?(refreshed.meta, "assignee")
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
          "status" => "active"
        })

      assert result =~ "Created goal: Ship v1"
      assert result =~ "ship-v1-goal"
      assert result =~ "status: active"

      goal = Goals.get_goal_by_slug("ship-v1-goal", ctx.id)
      assert goal.summary == "Launch the product"
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

  # ── Tool: dran_get_goal / dran_update_goal / dran_delete_goal ─────────────

  describe "dran_get_goal" do
    setup %{context: ctx} do
      {:ok, goal} =
        Goals.create_goal(%{
          workspace_id: ctx.id,
          title: "MCP Goals",
          summary: "test goal"
        })

      {:ok, _} = Goals.add_checklist_item(goal, "first item")
      goal = Goals.get_goal(goal.id)
      {:ok, goal: goal}
    end

    test "reads a goal by slug with checklist indices", %{context: ctx, goal: goal} do
      result = call_tool("dran_get_goal", %{"workspace" => "personal", "goal" => goal.slug})

      assert result =~ "Goal: MCP Goals"
      assert result =~ "Slug: #{goal.slug}"
      assert result =~ "ID: #{goal.id}"
      assert result =~ "Checklist (0/1 done)"
      assert result =~ "[ ] 0: first item"
    end

    test "reads a goal by UUID", %{goal: goal} do
      result = call_tool("dran_get_goal", %{"workspace" => "personal", "goal" => goal.id})
      assert result =~ "Goal: MCP Goals"
    end

    test "errors on unknown goal", %{context: _ctx} do
      result = call_tool("dran_get_goal", %{"workspace" => "personal", "goal" => "no-such"})
      assert result =~ "Error: goal 'no-such' not found"
    end

    test "errors on unknown context" do
      result = call_tool("dran_get_goal", %{"workspace" => "no-ctx", "goal" => "x"})
      assert result =~ "Error: context 'no-ctx' not found"
    end

    test "renders linked workflows and plan/project notes", %{
      context: ctx,
      goal: goal
    } do
      {:ok, _workflow} =
        Workflows.create_workflow(%{
          "workspace_id" => ctx.id,
          "goal_id" => goal.id,
          "title" => "Exec pipeline",
          "slug" => "exec-pipeline",
          "status" => "active"
        })

      {:ok, note} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Q4 Plan",
          slug: "q4-plan-mcp",
          body: "steps",
          page_type: "note",
          meta: %{"kind" => "plan"}
        })

      {:ok, _} = Goals.link_note(goal, note)

      result = call_tool("dran_get_goal", %{"workspace" => "personal", "goal" => goal.slug})

      assert result =~ "Linked workflows (1)"
      assert result =~ "exec-pipeline: Exec pipeline [active/evergreen]"
      assert result =~ "Linked plan/project notes (1)"
      assert result =~ "q4-plan-mcp: Q4 Plan (plan)"
    end
  end

  describe "dran_create_workflow" do
    setup %{context: ctx} do
      {:ok, goal} = Goals.create_goal(%{workspace_id: ctx.id, title: "MCP WF Goal"})
      {:ok, goal: goal}
    end

    test "creates a draft workflow with steps and a depends_on DAG", %{context: ctx, goal: goal} do
      result =
        call_tool("dran_create_workflow", %{
          "workspace" => "personal",
          "title" => "Bridge pipeline",
          "goal_slug" => goal.slug,
          "steps" => [
            %{"title" => "Survey", "intent" => "We need the lay of the land"},
            %{"title" => "Build", "depends_on" => ["Survey"]},
            %{"title" => "Verify", "depends_on" => ["Build"]}
          ]
        })

      assert result =~ "Created workflow: Bridge pipeline"
      assert result =~ "draft — 3 steps with DAG"

      slug = extract_slug(result)
      workflow = Workflows.get_workflow_by_slug(slug, ctx.id)

      assert workflow.status == "draft"
      assert workflow.goal_id == goal.id
      assert length(Workflows.list_steps(workflow)) == 3
    end

    test "fails with a clear error on unknown goal_slug" do
      result =
        call_tool("dran_create_workflow", %{
          "workspace" => "personal",
          "title" => "Orphan",
          "goal_slug" => "no-such-goal"
        })

      assert result =~ "Error: goal 'no-such-goal' not found"
    end

    test "errors on unknown context" do
      result =
        call_tool("dran_create_workflow", %{"workspace" => "no-ctx", "title" => "X"})

      assert result =~ "Error: context 'no-ctx' not found"
    end
  end

  describe "dran_update_goal" do
    setup %{context: ctx} do
      {:ok, goal} = Goals.create_goal(%{workspace_id: ctx.id, title: "Before Update"})
      {:ok, goal: goal}
    end

    test "updates status and summary", %{goal: goal} do
      result =
        call_tool("dran_update_goal", %{
          "workspace" => "personal",
          "goal" => goal.slug,
          "status" => "on_hold",
          "summary" => "paused for now"
        })

      assert result =~ "Updated goal: Before Update"
      assert result =~ "status: on_hold"
      updated = Goals.get_goal(goal.id) |> then(& &1)
      assert updated.summary == "paused for now"
    end

    test "regenerates slug from new title", %{goal: goal} do
      result =
        call_tool("dran_update_goal", %{
          "workspace" => "personal",
          "goal" => goal.slug,
          "title" => "After Update"
        })

      assert result =~ "Updated goal: After Update"
      assert result =~ "after-update"
      assert Goals.get_goal_by_slug("after-update", goal.workspace_id) != nil
    end

    test "errors on unknown goal" do
      result =
        call_tool("dran_update_goal", %{
          "workspace" => "personal",
          "goal" => "ghost",
          "status" => "done"
        })

      assert result =~ "Error: goal 'ghost' not found"
    end
  end

  describe "dran_delete_goal" do
    setup %{context: ctx} do
      {:ok, goal} = Goals.create_goal(%{workspace_id: ctx.id, title: "Doomed"})
      {:ok, goal: goal}
    end

    test "deletes the goal", %{goal: goal} do
      result = call_tool("dran_delete_goal", %{"workspace" => "personal", "goal" => goal.slug})
      assert result =~ "Deleted goal: Doomed"
      assert Goals.get_goal(goal.id) == nil
    end

    test "errors on unknown goal" do
      result = call_tool("dran_delete_goal", %{"workspace" => "personal", "goal" => "ghost"})
      assert result =~ "Error: goal 'ghost' not found"
    end
  end

  # ── Tool: goal checklist (planning sub-items) ──────────────────────────────

  describe "dran_goal_checklist_add" do
    setup %{context: ctx} do
      {:ok, goal} = Goals.create_goal(%{workspace_id: ctx.id, title: "Checklist Goal"})
      {:ok, goal: goal}
    end

    test "appends items with running index", %{goal: goal} do
      r1 =
        call_tool("dran_goal_checklist_add", %{
          "workspace" => "personal",
          "goal" => goal.slug,
          "text" => "alpha"
        })

      r2 =
        call_tool("dran_goal_checklist_add", %{
          "workspace" => "personal",
          "goal" => goal.slug,
          "text" => "beta"
        })

      assert r1 =~ "Added checklist item 0: \"alpha\" — progress: 0/1"
      assert r2 =~ "Added checklist item 1: \"beta\" — progress: 0/2"
    end

    test "rejects empty text", %{goal: goal} do
      result =
        call_tool("dran_goal_checklist_add", %{
          "workspace" => "personal",
          "goal" => goal.slug,
          "text" => "   "
        })

      assert result =~ "Error: checklist item text cannot be empty"
    end

    test "works with UUID handle", %{goal: goal} do
      result =
        call_tool("dran_goal_checklist_add", %{
          "workspace" => "personal",
          "goal" => goal.id,
          "text" => "by uuid"
        })

      assert result =~ "Added checklist item 0"
    end
  end

  describe "dran_goal_checklist_toggle" do
    setup %{context: ctx} do
      {:ok, goal} = Goals.create_goal(%{workspace_id: ctx.id, title: "Toggle Goal"})
      {:ok, _} = Goals.add_checklist_item(goal, "one")
      goal = Goals.get_goal(goal.id)
      {:ok, goal: goal}
    end

    test "flips done flag and reports progress", %{goal: goal} do
      result =
        call_tool("dran_goal_checklist_toggle", %{
          "workspace" => "personal",
          "goal" => goal.slug,
          "index" => 0
        })

      assert result =~ "Checklist item 0 'one' → done — progress: 1/1"

      result =
        call_tool("dran_goal_checklist_toggle", %{
          "workspace" => "personal",
          "goal" => goal.slug,
          "index" => 0
        })

      assert result =~ "Checklist item 0 'one' → open — progress: 0/1"
    end

    test "errors on out-of-bounds index", %{goal: goal} do
      result =
        call_tool("dran_goal_checklist_toggle", %{
          "workspace" => "personal",
          "goal" => goal.slug,
          "index" => 5
        })

      assert result =~ "Error: index 5 out of bounds (checklist has 1 items)"
    end
  end

  describe "dran_goal_checklist_remove" do
    setup %{context: ctx} do
      {:ok, goal} = Goals.create_goal(%{workspace_id: ctx.id, title: "Remove Goal"})
      {:ok, goal} = Goals.add_checklist_item(goal, "keep")
      {:ok, goal} = Goals.add_checklist_item(goal, "drop")
      {:ok, goal: goal}
    end

    test "removes the item at index", %{goal: goal} do
      result =
        call_tool("dran_goal_checklist_remove", %{
          "workspace" => "personal",
          "goal" => goal.slug,
          "index" => 1
        })

      assert result =~ "Removed checklist item 1: 'drop' — progress: 0/1"

      updated = Goals.get_goal(goal.id)
      assert length(updated.checklist) == 1
      assert hd(updated.checklist)["text"] == "keep"
    end

    test "errors on out-of-bounds index", %{goal: goal} do
      result =
        call_tool("dran_goal_checklist_remove", %{
          "workspace" => "personal",
          "goal" => goal.slug,
          "index" => 9
        })

      assert result =~ "Error: index 9 out of bounds"
    end
  end

  describe "dran_list_goals" do
    test "lists goals with checklist progress", %{context: ctx} do
      {:ok, goal} = Goals.create_goal(%{workspace_id: ctx.id, title: "Listed Goal"})
      {:ok, goal} = Goals.add_checklist_item(goal, "a")
      {:ok, goal} = Goals.add_checklist_item(goal, "b")
      {:ok, goal} = Goals.toggle_checklist_item(goal, 0)

      result = call_tool("dran_list_goals", %{"workspace" => "personal"})

      assert result =~ "Listed Goal (#{goal.slug}) — active — checklist: 1/2"
    end

    test "empty context message", %{context: _ctx} do
      # contexto nuevo sin goals
      Knowledge.create_workspace(%{name: "Empty Goals", slug: "empty-goals"})
      result = call_tool("dran_list_goals", %{"workspace" => "empty-goals"})
      assert result =~ "No goals in context 'empty-goals'"
    end

    test "errors on unknown context" do
      result = call_tool("dran_list_goals", %{"workspace" => "no-ctx"})
      assert result =~ "Error: context 'no-ctx' not found"
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

    test "filters by kind", %{context: ctx} do
      {:ok, _} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Meeting about roadmap",
          slug: "kind-filter-meeting",
          page_type: "note",
          meta: %{"kind" => "meeting"}
        })

      {:ok, _} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Idea for growth",
          slug: "kind-filter-idea",
          page_type: "note",
          meta: %{"kind" => "idea"}
        })

      result =
        call_tool("dran_list_pages", %{
          "workspace" => "personal",
          "kind" => "meeting"
        })

      assert result =~ "kind-filter-meeting"
      refute result =~ "kind-filter-idea"
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

  # ── Tools: workflows / steps / sessions / runs (Riel bridge) ──────────────

  defp wf_mcp_contract do
    %{
      "intent" => "Ship the MCP bridge",
      "status" => "active",
      "claims" => [
        %{"id" => "P1", "claim" => "runs close with evidence", "verify" => "mix test"}
      ],
      "gates" => [
        %{
          "name" => "compile",
          "check" => "mix compile",
          "expect" => "exit 0",
          "on_failure" => "fix"
        }
      ],
      "graph" => %{
        "nodes" => [
          %{"id" => "S1", "verb" => "READ", "label" => "mcp.ex"},
          %{"id" => "G1", "verb" => "VERIFY", "label" => "green?"}
        ],
        "edges" => [%{"from" => "S1", "to" => "G1", "guard" => "yes"}]
      }
    }
  end

  defp wf_mcp_step(workflow, title, contract \\ nil) do
    slug = "mcp-#{String.downcase(title)}-#{System.unique_integer([:positive])}"
    {:ok, step} = Workflows.create_step(workflow, %{"title" => title, "slug" => slug})

    if contract do
      {:ok, step} =
        Workflows.update_step(step, %{
          "intent" => contract["intent"],
          "status" => contract["status"] || "draft",
          "claims" => contract["claims"] || [],
          "gates" => contract["gates"] || [],
          "graph" => contract["graph"]
        })

      step
    else
      step
    end
  end

  # Workspace dedicado por test para los tests de workflows: aísla el
  # listado/fetch de cualquier residuo del "personal" compartido.
  defp wf_mcp_ws(_context) do
    slug = "wf-mcp-#{System.unique_integer([:positive])}"

    Knowledge.get_workspace_by_slug(slug) ||
      elem(Knowledge.create_workspace(%{name: "WF MCP", slug: slug}), 1)
  end

  defp wf_mcp_workflow(context) do
    {:ok, workflow} =
      Workflows.create_workflow(%{
        "workspace_id" => context.id,
        "title" => "Riel Bridge #{System.unique_integer([:positive])}",
        "slug" => "riel-bridge-#{System.unique_integer([:positive])}",
        "status" => "active"
      })

    Dran.Repo.reload!(workflow)
  end

  describe "dran_list_workflows" do
    test "lists workflows with step counts", %{context: ctx} do
      ws = wf_mcp_ws(ctx)
      wf = wf_mcp_workflow(ws)
      wf_mcp_step(wf, "Alpha")

      result = call_tool("dran_list_workflows", %{"workspace" => ws.slug})

      assert result =~ "• #{wf.title} (#{wf.slug})"
      assert result =~ "steps: 1"
    end

    test "errors on unknown context" do
      result = call_tool("dran_list_workflows", %{"workspace" => "no-ctx"})
      assert result =~ "Error: context 'no-ctx' not found"
    end
  end

  describe "dran_get_workflow" do
    test "shows steps with contract validity and prereq counts", %{context: ctx} do
      ws = wf_mcp_ws(ctx)
      wf = wf_mcp_workflow(ws)
      s1 = wf_mcp_step(wf, "First", wf_mcp_contract())
      s2 = wf_mcp_step(wf, "Second")
      {:ok, _} = Contracts.add_dependency(s2, s1)

      result = call_tool("dran_get_workflow", %{"workspace" => ws.slug, "workflow" => wf.slug})

      assert result =~ "Workflow: #{wf.title}"
      assert result =~ "(#{s1.slug})"
      assert result =~ "contract ✓"
      assert result =~ "(#{s2.slug})"
      assert result =~ "prereqs: 1"
    end

    test "accepts UUID handle", %{context: ctx} do
      ws = wf_mcp_ws(ctx)
      wf = wf_mcp_workflow(ws)
      result = call_tool("dran_get_workflow", %{"workspace" => ws.slug, "workflow" => wf.id})
      assert result =~ "Workflow: #{wf.title}"
    end

    test "errors on unknown workflow" do
      ws = wf_mcp_ws(nil)
      result = call_tool("dran_get_workflow", %{"workspace" => ws.slug, "workflow" => "ghost"})
      assert result =~ "Error: workflow 'ghost' not found"
    end
  end

  describe "dran_get_step_contract" do
    test "renders structured contract and the riel brief", %{context: ctx} do
      ws = wf_mcp_ws(ctx)
      wf = wf_mcp_workflow(ws)
      step = wf_mcp_step(wf, "Contracted", wf_mcp_contract())

      result =
        call_tool("dran_get_step_contract", %{
          "workspace" => ws.slug,
          "workflow" => wf.slug,
          "step" => step.slug
        })

      assert result =~ "Step: Contracted"
      assert result =~ "intent:"
      assert result =~ "P1"
      assert result =~ "## Objective"
      assert result =~ "We need Ship the MCP bridge"
      assert result =~ "## DO NOT"
    end

    test "step without contract degrades gracefully", %{context: ctx} do
      ws = wf_mcp_ws(ctx)
      wf = wf_mcp_workflow(ws)
      step = wf_mcp_step(wf, "Bare")

      result =
        call_tool("dran_get_step_contract", %{
          "workspace" => ws.slug,
          "workflow" => wf.slug,
          "step" => step.slug
        })

      assert result =~ "Step: Bare"
      assert result =~ "(none)"
      assert result =~ "no valid contract"
    end

    test "errors on unknown step", %{context: ctx} do
      ws = wf_mcp_ws(ctx)
      wf = wf_mcp_workflow(ws)

      result =
        call_tool("dran_get_step_contract", %{
          "workspace" => ws.slug,
          "workflow" => wf.slug,
          "step" => "ghost-step"
        })

      assert result =~ "Error: step 'ghost-step' not found"
    end
  end

  describe "dran_open_workflow_session" do
    test "opens a session with one pending run per step", %{context: ctx} do
      ws = wf_mcp_ws(ctx)
      wf = wf_mcp_workflow(ws)
      s1 = wf_mcp_step(wf, "One", wf_mcp_contract())
      s2 = wf_mcp_step(wf, "Two")
      {:ok, _} = Contracts.add_dependency(s2, s1)

      result =
        call_tool("dran_open_workflow_session", %{
          "workspace" => ws.slug,
          "workflow" => wf.slug,
          "label" => "mcp test"
        })

      assert result =~ "Session opened:"
      assert result =~ "2 runs created"
      assert result =~ "step: #{s1.slug} — pending (ready)"
      assert result =~ "step: #{s2.slug} — pending (blocked)"
    end

    test "errors on workflow without steps", %{context: ctx} do
      ws = wf_mcp_ws(ctx)
      wf = wf_mcp_workflow(ws)

      result =
        call_tool("dran_open_workflow_session", %{
          "workspace" => ws.slug,
          "workflow" => wf.slug
        })

      assert result =~ "Error: could not open session"
    end
  end

  describe "execution cycle: pending → start → progress → close" do
    setup %{context: ctx} do
      ws = wf_mcp_ws(ctx)
      wf = wf_mcp_workflow(ws)
      step = wf_mcp_step(wf, "Solo", wf_mcp_contract())
      {:ok, session} = Executions.open_session(wf, label: "cycle")
      run = Enum.find(session.runs, &(&1.step_id == step.id))
      {:ok, run: run, step: step, session: session, workflow: wf, ws: ws}
    end

    test "dran_list_pending_runs shows the queue", %{run: run, step: step, ws: ws} do
      result = call_tool("dran_list_pending_runs", %{"workspace" => ws.slug})

      assert result =~ "run #{run.id}"
      assert result =~ "step: #{step.slug}"
      assert result =~ "(attempt 1) — ready"
    end

    test "full cycle: start, progress, close, session closes", %{
      context: _ctx,
      run: run,
      session: session
    } do
      started = call_tool("dran_start_run", %{"run_id" => run.id})
      assert started =~ "Run started: #{run.id}"
      assert started =~ "status: in_flight"

      progress =
        call_tool("dran_report_run_progress", %{
          "run_id" => run.id,
          "progress" => %{"01" => "gate compile passed"}
        })

      assert progress =~ "Progress recorded on run #{run.id}"
      assert progress =~ "1 checkpoint(s)"

      closed =
        call_tool("dran_close_run", %{
          "run_id" => run.id,
          "status" => "passed",
          "outcome" => "all gates green"
        })

      assert closed =~ "Run closed: #{run.id} — passed"
      assert closed =~ "all gates green"

      # el cierre del último run cierra la sesión como passed
      closed_session = Dran.Repo.reload!(session)
      assert closed_session.status == "passed"
    end

    test "failed run can be retried", %{context: _ctx, run: run} do
      {:ok, run} = Executions.start_run(run)
      call_tool("dran_close_run", %{"run_id" => run.id, "status" => "failed"})

      result = call_tool("dran_retry_run", %{"run_id" => run.id})
      assert result =~ "Retry created:"
      assert result =~ "attempt 2"
      assert result =~ "status: pending"
    end

    test "start on unknown run errors" do
      result = call_tool("dran_start_run", %{"run_id" => Ecto.UUID.generate()})
      assert result =~ "Error: run"
    end

    test "progress on non-started run errors", %{run: run} do
      result =
        call_tool("dran_report_run_progress", %{
          "run_id" => run.id,
          "progress" => %{"x" => "y"}
        })

      assert result =~ "Error: could not record progress"
    end
  end
end
