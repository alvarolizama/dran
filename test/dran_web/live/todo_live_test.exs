defmodule DranWeb.TodoLiveTest do
  use DranWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Dran.Brain

  setup %{conn: conn} do
    original = Application.get_env(:dran, :inference)

    Application.put_env(:dran, :inference,
      api_url: "http://localhost:99999",
      api_key: "test-key"
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
        body: "A todo for the list realtime test",
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

  test "todo list renders rows with status buttons", %{conn: conn, todo: todo} do
    {:ok, view, _html} = live(conn, ~p"/todos")

    assert has_element?(view, ~s([data-testid="todo-list"]))
    assert has_element?(view, ~s([data-testid="todo-row-#{todo.slug}"]))

    # Status quick-change buttons exist for each kanban column
    for status <- ~w(backlog this_week today in_progress done cancelled) do
      assert has_element?(view, ~s(button[phx-value-status="#{status}"]))
    end
  end

  test "todo list updates in real time when a page changes via PubSub", %{
    conn: conn,
    todo: todo
  } do
    {:ok, view, html} = live(conn, ~p"/todos")

    assert html =~ "Kanban Realtime Test Todo"
    assert has_element?(view, ~s([data-testid="todo-row-#{todo.slug}"]))

    # Archive it externally — the list should drop it on re-render
    {:ok, _updated} = Brain.update_page(todo, %{archived: true})

    html = render(view)
    refute has_element?(view, ~s([data-testid="todo-row-#{todo.slug}"]))
    # And the archived toggle now reports one archived item
    assert html =~ "(1)"
  end

  test "todo list picks up todos created by an agent in real time", %{
    conn: conn,
    context: context
  } do
    {:ok, view, _html} = live(conn, ~p"/todos")

    {:ok, agent_todo} =
      Brain.create_page(%{
        context_id: context.id,
        title: "Agent Created Todo Live",
        body: "Created while the list was open",
        page_type: "todo",
        meta: %{"kanban_status" => "today"}
      })

    assert has_element?(view, ~s([data-testid="todo-row-#{agent_todo.slug}"]))
  end

  test "change_status button updates the todo's kanban status", %{conn: conn, todo: todo} do
    {:ok, view, _html} = live(conn, ~p"/todos")

    view
    |> element(~s(button[phx-value-slug="#{todo.slug}"][phx-value-status="today"]))
    |> render_click()

    assert Brain.get_page_by_slug(todo.slug, todo.context_id).meta["kanban_status"] == "today"
  end
end
