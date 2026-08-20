defmodule Dran.SmartCollectionTest do
  use Dran.DataCase, async: false

  alias Dran.Knowledge
  alias Dran.SmartCollection

  setup do
    # Disable inference entirely for tests — no PageAugmenter calls
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

    context = Knowledge.get_workspace_by_slug("personal")
    {:ok, context: context}
  end

  # ── query_to_opts/1 ──

  describe "query_to_opts/1" do
    test "parses a full query map into keyword options" do
      query = %{
        "type" => "todo",
        "tag" => "urgent",
        "status" => "in_progress",
        "owner" => "alvaro",
        "due_before" => "2026-07-20",
        "due_after" => "2026-07-01"
      }

      opts = SmartCollection.query_to_opts(query)

      # "todo" maps to note + kind todo in the new model
      assert Keyword.get(opts, :type) == "note"
      assert Keyword.get(opts, :kind) == "todo"
      assert Keyword.get(opts, :tag) == "urgent"
      assert Keyword.get(opts, :status) == "in_progress"
      assert Keyword.get(opts, :owner) == "alvaro"
      assert Keyword.get(opts, :due_before) == "2026-07-20"
      assert Keyword.get(opts, :due_after) == "2026-07-01"
    end

    test "returns empty list for nil" do
      assert SmartCollection.query_to_opts(nil) == []
    end

    test "returns empty list for empty map" do
      assert SmartCollection.query_to_opts(%{}) == []
    end

    test "skips nil and empty string values" do
      query = %{"type" => "todo", "tag" => "", "status" => nil}
      opts = SmartCollection.query_to_opts(query)

      assert Keyword.get(opts, :type) == "note"
      assert Keyword.get(opts, :kind) == "todo"
      refute Keyword.has_key?(opts, :tag)
      refute Keyword.has_key?(opts, :status)
    end

    test "resolves <today> to current date for due_before" do
      query = %{"due_before" => "<today>"}
      opts = SmartCollection.query_to_opts(query)

      today = Date.utc_today() |> Date.to_iso8601()
      assert Keyword.get(opts, :due_before) == today
    end

    test "resolves <today> to current date for due_after" do
      query = %{"due_after" => "<today>"}
      opts = SmartCollection.query_to_opts(query)

      today = Date.utc_today() |> Date.to_iso8601()
      assert Keyword.get(opts, :due_after) == today
    end

    test "supports atom keys in query map" do
      query = %{type: "note", tag: "elixir"}
      opts = SmartCollection.query_to_opts(query)

      assert Keyword.get(opts, :type) == "note"
      assert Keyword.get(opts, :tag) == "elixir"
    end
  end

  # ── build_query/1 ──

  describe "build_query/1" do
    test "builds clean query from params, stripping empties" do
      params = %{"type" => "todo", "status" => "", "tag" => "urgent", "owner" => nil}
      query = SmartCollection.build_query(params)

      assert query["type"] == "todo"
      assert query["tag"] == "urgent"
      refute Map.has_key?(query, "status")
      refute Map.has_key?(query, "owner")
    end

    test "returns empty map for all-empty params" do
      params = %{"type" => "", "tag" => "", "status" => nil}
      assert SmartCollection.build_query(params) == %{}
    end

    test "includes date fields when provided" do
      params = %{"due_before" => "2026-07-20", "due_after" => "2026-07-01"}
      query = SmartCollection.build_query(params)

      assert query["due_before"] == "2026-07-20"
      assert query["due_after"] == "2026-07-01"
    end

    test "trims whitespace from values" do
      params = %{"type" => "  todo  ", "tag" => " urgent "}
      query = SmartCollection.build_query(params)

      assert query["type"] == "todo"
      assert query["tag"] == "urgent"
    end
  end

  # ── create/1 ──

  describe "create/1" do
    test "creates a smart collection page with query in meta", %{context: context} do
      attrs = %{
        "workspace_id" => context.id,
        "title" => "Urgent Todos",
        "query" => %{"type" => "todo", "status" => "in_progress"},
        "created_by" => "test"
      }

      assert {:ok, page} = SmartCollection.create(attrs)
      assert page.page_type == "note"
      assert page.title == "Urgent Todos"
      assert page.meta["query"]["type"] == "todo"
      assert page.meta["query"]["status"] == "in_progress"
    end

    test "auto-generates slug from title", %{context: context} do
      attrs = %{
        "workspace_id" => context.id,
        "title" => "My Collection",
        "query" => %{}
      }

      assert {:ok, page} = SmartCollection.create(attrs)
      assert page.slug == "my-collection"
    end

    test "generates summary from query when not provided", %{context: context} do
      attrs = %{
        "workspace_id" => context.id,
        "title" => "Test Collection",
        "query" => %{"type" => "todo", "status" => "backlog"}
      }

      assert {:ok, page} = SmartCollection.create(attrs)
      assert page.summary =~ "type: todo"
      assert page.summary =~ "status: backlog"
    end

    test "uses 'All pages' summary for empty query", %{context: context} do
      attrs = %{
        "workspace_id" => context.id,
        "title" => "Everything",
        "query" => %{}
      }

      assert {:ok, page} = SmartCollection.create(attrs)
      assert page.summary == "All pages"
    end
  end

  # ── get_by_slug/2 ──

  describe "get_by_slug/2" do
    test "returns the collection page when found", %{context: context} do
      {:ok, page} =
        SmartCollection.create(%{
          "workspace_id" => context.id,
          "title" => "Find Me",
          "query" => %{"type" => "note"}
        })

      found = SmartCollection.get_by_slug(page.slug, context.id)
      assert found.id == page.id
      assert found.page_type == "note"
    end

    test "returns nil when page is not a collection (no meta.query)", %{context: context} do
      {:ok, note} =
        Knowledge.create_page(%{
          workspace_id: context.id,
          title: "A Note",
          slug: "a-note",
          page_type: "note",
          body: "content"
        })

      assert SmartCollection.get_by_slug(note.slug, context.id) == nil
    end

    test "returns nil when page doesn't exist", %{context: context} do
      assert SmartCollection.get_by_slug("nonexistent", context.id) == nil
    end
  end

  # ── list_all/1 ──

  describe "list_all/1" do
    test "lists all collection pages in a context", %{context: context} do
      SmartCollection.create(%{
        "workspace_id" => context.id,
        "title" => "Collection One",
        "query" => %{"type" => "note"}
      })

      SmartCollection.create(%{
        "workspace_id" => context.id,
        "title" => "Collection Two",
        "query" => %{"type" => "todo"}
      })

      collections = SmartCollection.list_all(context.id)
      titles = Enum.map(collections, & &1.title)

      assert "Collection One" in titles
      assert "Collection Two" in titles
    end

    test "does not include non-collection note pages", %{context: context} do
      Knowledge.create_page(%{
        workspace_id: context.id,
        title: "A Note",
        slug: "a-regular-note",
        page_type: "note",
        body: "content"
      })

      collections = SmartCollection.list_all(context.id)
      slugs = Enum.map(collections, & &1.slug)

      refute "a-regular-note" in slugs
    end
  end

  # ── execute/2 ──

  describe "execute/2" do
    test "returns pages matching the query filters", %{context: context} do
      # Create test pages
      Knowledge.create_page(%{
        workspace_id: context.id,
        title: "Todo One",
        slug: "todo-one",
        page_type: "note",
        body: "content",
        meta: %{"kind" => "todo", "kanban_status" => "in_progress"},
        kanban_status: "in_progress"
      })

      Knowledge.create_page(%{
        workspace_id: context.id,
        title: "Note One",
        slug: "note-one",
        page_type: "note",
        body: "content"
      })

      query = %{"type" => "todo"}
      results = SmartCollection.execute(query, context.id)

      slugs = Enum.map(results, & &1.slug)
      assert "todo-one" in slugs
      refute "note-one" in slugs
    end

    test "returns all pages for nil query", %{context: context} do
      results = SmartCollection.execute(nil, context.id)
      assert is_list(results)
    end

    test "returns all pages for empty query", %{context: context} do
      results = SmartCollection.execute(%{}, context.id)
      assert is_list(results)
    end

    test "filters by status", %{context: context} do
      Knowledge.create_page(%{
        workspace_id: context.id,
        title: "Active Todo",
        slug: "active-todo",
        page_type: "note",
        body: "content",
        meta: %{"kind" => "todo", "kanban_status" => "in_progress"},
        kanban_status: "in_progress"
      })

      Knowledge.create_page(%{
        workspace_id: context.id,
        title: "Done Todo",
        slug: "done-todo",
        page_type: "note",
        body: "content",
        meta: %{"kind" => "todo", "kanban_status" => "done"},
        kanban_status: "done"
      })

      results = SmartCollection.execute(%{"status" => "in_progress"}, context.id)
      slugs = Enum.map(results, & &1.slug)

      assert "active-todo" in slugs
      refute "done-todo" in slugs
    end

    test "filters by tag", %{context: context} do
      Knowledge.create_page(%{
        workspace_id: context.id,
        title: "Tagged Note",
        slug: "tagged-note",
        page_type: "note",
        body: "content",
        tags: ["urgent", "work"]
      })

      Knowledge.create_page(%{
        workspace_id: context.id,
        title: "Untagged Note",
        slug: "untagged-note",
        page_type: "note",
        body: "content",
        tags: []
      })

      results = SmartCollection.execute(%{"tag" => "urgent"}, context.id)
      slugs = Enum.map(results, & &1.slug)

      assert "tagged-note" in slugs
      refute "untagged-note" in slugs
    end
  end
end
