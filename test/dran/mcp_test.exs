defmodule Dran.MCPTest do
  use Dran.DataCase, async: false

  alias Dran.{Brain, MCP, Repo}
  alias Dran.Brain.Page

  # Same setup as brain_test.exs: disable inference so dran_create_page doesn't
  # call external APIs, and ensure the "personal" context exists.
  setup do
    original = Application.get_env(:dran, :inference)

    Application.put_env(:dran, :inference,
      base_url: nil,
      api_key: nil,
      embedding_model: nil,
      rerank_model: nil,
      markitdown_model: nil,
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
        Brain.create_page(%{
          context_id: ctx.id,
          title: "Artifact",
          slug: "old-art",
          page_type: "artifact"
        })

      # Page that embeds it.
      {:ok, note} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "Note",
          slug: "note-with-embed",
          page_type: "note",
          body: "See ![[old-art]] for details"
        })

      result =
        call_tool("dran_rename_slug", %{
          "context" => "personal",
          "old_slug" => "old-art",
          "new_slug" => "new-art"
        })

      assert result =~ "Renamed 'old-art' → 'new-art'"
      assert result =~ "![[old-art]]"

      # The renamed page's slug changed.
      assert Repo.get!(Page, art.id).slug == "new-art"

      # The embedding page's body was rewritten to reference the new slug.
      refreshed = Brain.get_page!(note.id)
      assert refreshed.body =~ "![[new-art]]"
      refute refreshed.body =~ "![[old-art]]"
    end

    test "errors when old_slug is not found", %{context: _ctx} do
      result =
        call_tool("dran_rename_slug", %{
          "context" => "personal",
          "old_slug" => "nope",
          "new_slug" => "still-nope"
        })

      assert result =~ "Error: page 'nope' not found"
    end

    test "errors when new_slug already exists", %{context: ctx} do
      {:ok, _a} =
        Brain.create_page(%{context_id: ctx.id, title: "A", slug: "exists-a", page_type: "note"})

      {:ok, b} =
        Brain.create_page(%{context_id: ctx.id, title: "B", slug: "exists-b", page_type: "note"})

      result =
        call_tool("dran_rename_slug", %{
          "context" => "personal",
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
        Brain.create_page(%{
          context_id: ctx.id,
          title: "Stale",
          slug: "stale-page",
          page_type: "note",
          body: "some body"
        })

      # Seed a non-nil embedding_hash to simulate a previously augmented page.
      Ecto.Changeset.change(page, embedding_hash: "some-old-hash") |> Repo.update!()

      result = call_tool("dran_reaugment_page", %{"context" => "personal", "slug" => "stale-page"})

      assert result =~ "Reaugmentation scheduled for 'stale-page'"

      refreshed = Repo.get!(Page, page.id)
      assert is_nil(refreshed.embedding_hash)
    end

    test "errors when page is not found", %{context: _ctx} do
      result = call_tool("dran_reaugment_page", %{"context" => "personal", "slug" => "missing"})

      assert result =~ "Error: page 'missing' not found"
    end

    test "errors when context is not found" do
      result =
        call_tool("dran_reaugment_page", %{"context" => "no-such-context", "slug" => "whatever"})

      assert result =~ "Error: context 'no-such-context' not found"
    end
  end

  describe "dran_list_pages with owner/created_by filters (4.3)" do
    test "filters by created_by", %{context: ctx} do
      {:ok, _alice} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "Alice's note",
          slug: "alice-note",
          page_type: "note",
          created_by: "alice"
        })

      {:ok, _bob} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "Bob's note",
          slug: "bob-note",
          page_type: "note",
          created_by: "bob"
        })

      result = call_tool("dran_list_pages", %{"context" => "personal", "created_by" => "alice"})

      assert result =~ "Found 1 pages"
      assert result =~ "alice-note"
      refute result =~ "bob-note"
    end

    test "filters by owner", %{context: ctx} do
      {:ok, _} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "Owned by team",
          slug: "team-owned",
          page_type: "note",
          owner: "team"
        })

      {:ok, _} =
        Brain.create_page(%{
          context_id: ctx.id,
          title: "Owned by agent",
          slug: "agent-owned",
          page_type: "note",
          owner: "agent"
        })

      result = call_tool("dran_list_pages", %{"context" => "personal", "owner" => "team"})

      assert result =~ "Found 1 pages"
      assert result =~ "team-owned"
      refute result =~ "agent-owned"
    end
  end
end
