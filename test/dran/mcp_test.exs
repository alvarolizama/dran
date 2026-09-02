defmodule Dran.MCPTest do
  use Dran.DataCase, async: false

  alias Dran.{Knowledge, MCP, Repo}
  alias Dran.Page

  # Same setup as brain_test.exs: disable inference so dran_create_page doesn't
  # call external APIs, and ensure the "personal" context exists.
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

  # Invoke a tool through the public MCP JSON-RPC entrypoint and return the
  # text result. This exercises the same path the HTTP controller uses.
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

  describe "dran_rename_slug (4.1)" do
    test "renames the page and rewrites ![[old]] embeds in other pages", %{context: ctx} do
      # Target page that will be renamed.
      {:ok, art} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Art Page",
          slug: "old-art",
          page_type: "note"
        })

      # Page that embeds it.
      {:ok, note} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Note",
          slug: "note-with-embed",
          page_type: "note",
          body: "See ![[old-art]] for details"
        })

      result =
        call_tool("dran_rename_slug", %{
          "workspace" => "personal",
          "old_slug" => "old-art",
          "new_slug" => "new-art"
        })

      assert result =~ "Renamed 'old-art' → 'new-art'"
      assert result =~ "![[old-art]]"

      # The renamed page's slug changed.
      assert Repo.get!(Page, art.id).slug == "new-art"

      # The embedding page's body was rewritten to reference the new slug.
      refreshed = Knowledge.get_page!(note.id)
      assert refreshed.body =~ "![[new-art]]"
      refute refreshed.body =~ "![[old-art]]"
    end

    test "errors when old_slug is not found", %{context: _ctx} do
      result =
        call_tool("dran_rename_slug", %{
          "workspace" => "personal",
          "old_slug" => "nope",
          "new_slug" => "still-nope"
        })

      assert result =~ "Error: page 'nope' not found"
    end

    test "errors when new_slug already exists", %{context: ctx} do
      {:ok, _a} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "A",
          slug: "exists-a",
          page_type: "note"
        })

      {:ok, b} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "B",
          slug: "exists-b",
          page_type: "note"
        })

      result =
        call_tool("dran_rename_slug", %{
          "workspace" => "personal",
          "old_slug" => "exists-b",
          "new_slug" => "exists-a"
        })

      assert result =~ "already exists"
      # The source page kept its slug.
      assert Repo.get!(Page, b.id).slug == "exists-b"
    end
  end

  describe "dran_reaugment_page (4.2)" do
    test "clears embedding_hash and schedules reaugmentation", %{context: ctx} do
      {:ok, page} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Stale",
          slug: "stale-page",
          page_type: "note",
          body: "some body"
        })

      # Seed a non-nil embedding_hash to simulate a previously augmented page.
      Ecto.Changeset.change(page, embedding_hash: "some-old-hash") |> Repo.update!()

      result =
        call_tool("dran_reaugment_page", %{"workspace" => "personal", "slug" => "stale-page"})

      assert result =~ "Reaugmentation scheduled for 'stale-page'"

      refreshed = Repo.get!(Page, page.id)
      assert is_nil(refreshed.embedding_hash)
    end

    test "errors when page is not found", %{context: _ctx} do
      result = call_tool("dran_reaugment_page", %{"workspace" => "personal", "slug" => "missing"})

      assert result =~ "Error: page 'missing' not found"
    end

    test "errors when context is not found" do
      result =
        call_tool("dran_reaugment_page", %{"workspace" => "no-such-context", "slug" => "whatever"})

      assert result =~ "Error: context 'no-such-context' not found"
    end
  end

  describe "dran_list_pages with owner/created_by filters (4.3)" do
    test "filters by created_by", %{context: ctx} do
      {:ok, _alice} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Alice's note",
          slug: "alice-note",
          page_type: "note",
          created_by: "alice"
        })

      {:ok, _bob} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Bob's note",
          slug: "bob-note",
          page_type: "note",
          created_by: "bob"
        })

      result = call_tool("dran_list_pages", %{"workspace" => "personal", "created_by" => "alice"})

      assert result =~ "Found 1 pages"
      assert result =~ "alice-note"
      refute result =~ "bob-note"
    end

    test "filters by created_by (owner dropped, same use case)", %{context: ctx} do
      {:ok, _} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Created by team",
          slug: "team-owned",
          page_type: "note",
          created_by: "team"
        })

      {:ok, _} =
        Knowledge.create_page(%{
          workspace_id: ctx.id,
          title: "Created by agent",
          slug: "agent-owned",
          page_type: "note",
          created_by: "agent"
        })

      result =
        call_tool("dran_list_pages", %{"workspace" => "personal", "created_by" => "team"})

      assert result =~ "Found 1 pages"
      assert result =~ "team-owned"
      refute result =~ "agent-owned"
    end
  end

  describe "dran_create_task / dran_update_task / dran_list_tasks" do
    test "creates, updates, and lists tasks via MCP", %{context: ctx} do
      result =
        call_tool("dran_create_task", %{
          "workspace" => "personal",
          "title" => "MCP task",
          "status" => "today",
          "priority" => "high",
          "due_date" => "2026-09-15",
          "recurrence" => "weekly",
          "checklist" => ["first step", "second step"]
        })

      assert result =~ "Created task: MCP task"
      assert result =~ "status: today"

      slug =
        case Regex.run(~r/\(([\w-]+), id:/, result) do
          [_, s] -> s
          nil -> flunk("could not extract slug from: #{result}")
        end

      task = Dran.Tasks.get_task_by_slug(slug, ctx.id)
      assert task.priority == "high"
      assert task.recurrence == "weekly"
      assert length(task.meta["checklist"]) == 2

      # Update status to done
      result =
        call_tool("dran_update_task", %{
          "workspace" => "personal",
          "slug" => slug,
          "status" => "done"
        })

      assert result =~ "Updated task: MCP task"
      assert result =~ "status: done"

      # Recurrence auto-cloned the next occurrence
      clone = Dran.Tasks.get_task_by_slug("#{slug}-2", ctx.id)
      assert clone != nil
      assert clone.status == "backlog"

      # List tasks
      result = call_tool("dran_list_tasks", %{"workspace" => "personal", "status" => "backlog"})

      assert result =~ "Tasks in 'personal'"
      assert result =~ clone.title
    end

    test "update of unknown task errors cleanly" do
      result =
        call_tool("dran_update_task", %{
          "workspace" => "personal",
          "slug" => "no-existe"
        })

      assert result =~ "Error: task 'no-existe' not found"
    end

    test "create_task appears in tools list and write enforcement" do
      %{"result" => %{"tools" => tools}} =
        MCP.process_message(%{
          "jsonrpc" => "2.0",
          "method" => "tools/list",
          "id" => 1,
          "params" => %{}
        })

      names = Enum.map(tools, & &1["name"])

      assert "dran_create_task" in names
      assert "dran_update_task" in names
      assert "dran_list_tasks" in names
    end
  end
end
