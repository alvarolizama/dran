defmodule DranWeb.TodoLiveTest do
  use DranWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Dran.Brain

  setup %{conn: conn} do
    # Disable inference scheduling so create_page doesn't try external APIs
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

    context = Brain.get_context_by_slug("personal")

    {:ok, todo} =
      Brain.create_page(%{
        context_id: context.id,
        title: "Kanban Realtime Test Todo",
        body: "A todo for the kanban realtime test",
        page_type: "todo",
        meta: %{"kanban_status" => "backlog"}
      })

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user, "test_user")
      |> Plug.Conn.put_session(:context_slug, "personal")

    {:ok, conn: conn, todo: todo, context: context}
  end

  test "kanban board renders full-viewport layout with all columns", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/todos")

    # Board container exists and carries the full-height class
    assert has_element?(view, "#kanban-board")
    board_class = view |> element("#kanban-board") |> render() |> then(& &1)
    assert board_class =~ "h-[calc(100vh-4rem)]"

    # All six kanban columns are present
    for status <- ~w(backlog this_week today in_progress done cancelled) do
      assert has_element?(view, ~s([data-kanban-status="#{status}"]))
    end
  end

  test "kanban board updates in real time when a page changes via PubSub", %{
    conn: conn,
    todo: todo,
    context: _context
  } do
    {:ok, view, html} = live(conn, ~p"/todos")

    # The todo starts in the backlog column
    backlog_column =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s([data-kanban-status="backlog"]))

    assert LazyHTML.text(backlog_column) =~ "Kanban Realtime Test Todo"

    # Simulate an agent moving the todo to done (e.g. via MCP update_todo) —
    # Brain.update_page broadcasts the change over PubSub.
    {:ok, _updated} =
      Brain.update_page(todo, %{meta: Map.merge(todo.meta || %{}, %{"kanban_status" => "done"})})

    # The LiveView should have received {:page_changed, ...} and reloaded items
    html = render(view)

    done_column =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s([data-kanban-status="done"]))

    assert LazyHTML.text(done_column) =~ "Kanban Realtime Test Todo"

    backlog_column =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s([data-kanban-status="backlog"]))

    refute LazyHTML.text(backlog_column) =~ "Kanban Realtime Test Todo"
  end

  test "kanban board picks up todos created by an agent in real time", %{
    conn: conn,
    context: context
  } do
    {:ok, view, _html} = live(conn, ~p"/todos")

    {:ok, _agent_todo} =
      Brain.create_page(%{
        context_id: context.id,
        title: "Agent Created Todo Live",
        body: "Created while the board was open",
        page_type: "todo",
        meta: %{"kanban_status" => "today"}
      })

    html = render(view)

    today_column =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s([data-kanban-status="today"]))

    assert LazyHTML.text(today_column) =~ "Agent Created Todo Live"
  end

  # ── Filters ──

  test "kanban filter bar renders with goal/plan selects and search input", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/todos")

    assert has_element?(view, "form#kanban-filters")
    assert has_element?(view, "#filter-goal")
    assert has_element?(view, "#filter-plan")
    assert has_element?(view, "#filter-query")
  end

  test "kanban text filter narrows cards and clear restores them", %{
    conn: conn,
    todo: todo,
    context: context
  } do
    {:ok, other} =
      Brain.create_page(%{
        context_id: context.id,
        title: "Completely Different Zzz Title",
        body: "other",
        page_type: "todo",
        meta: %{"kanban_status" => "backlog"}
      })

    {:ok, view, _html} = live(conn, ~p"/todos")

    # Both cards visible initially
    html = render(view)
    assert html =~ "Kanban Realtime Test Todo"
    assert html =~ "Completely Different Zzz Title"

    # Type a query matching only the fixture todo
    view
    |> element("form#kanban-filters")
    |> render_change(%{"filter_query" => "Kanban Realtime"})

    html = render(view)
    assert html =~ "Kanban Realtime Test Todo"
    refute html =~ "Completely Different Zzz Title"

    # Clear filters restores both
    view |> element("button", "Clear filters") |> render_click()
    html = render(view)
    assert html =~ "Kanban Realtime Test Todo"
    assert html =~ "Completely Different Zzz Title"
  end

  test "kanban goal filter shows only todos of that goal", %{
    conn: conn,
    todo: _todo,
    context: context
  } do
    {:ok, goal} =
      Brain.create_page(%{
        context_id: context.id,
        title: "Filter Goal Xyz",
        body: "goal",
        page_type: "goal"
      })

    {:ok, _linked} =
      Brain.create_page(%{
        context_id: context.id,
        title: "Linked To Goal Xyz",
        body: "linked",
        page_type: "todo",
        meta: %{"kanban_status" => "backlog", "goal_slug" => goal.slug}
      })

    {:ok, view, _html} = live(conn, ~p"/todos")

    view
    |> element("form#kanban-filters")
    |> render_change(%{"filter_goal" => goal.slug})

    html = render(view)
    assert html =~ "Linked To Goal Xyz"
    refute html =~ "Kanban Realtime Test Todo"
  end
end
