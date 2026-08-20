defmodule DranWeb.KanbanLiveTest do
  use DranWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Dran.Brain

  # Gettext wrapper — the app default locale is "es", so assertions must
  # match the translated strings, not the English msgids.
  defp t(msgid), do: Gettext.gettext(DranWeb.Gettext, msgid)

  setup %{conn: conn} do
    # Disable inference scheduling so create_page doesn't try external APIs
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

    context = Brain.get_workspace_by_slug("personal")

    # A goal via the new Goal table so the goal-filter test has a real slug.
    {:ok, goal} =
      Brain.create_goal(%{
        workspace_id: context.id,
        title: "Kanban Test Goal",
        slug: "kanban-test-goal"
      })

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user, "test_user")
      |> Plug.Conn.put_session(:workspace_slug, "personal")

    {:ok, conn: conn, context: context, goal: goal}
  end

  describe "quick-add form" do
    test "creates a todo in backlog with default priority medium", %{
      conn: conn,
      context: context
    } do
      {:ok, view, _html} = live(conn, ~p"/panel/kanban")

      # Form is hidden until the toggle button is clicked.
      refute has_element?(view, "#kanban-quick-add")

      view |> element("button", t("Nueva tarea")) |> render_click()
      assert has_element?(view, "#kanban-quick-add")

      html =
        view
        |> form("#kanban-quick-add", %{
          "title" => "Quick Add Test Todo",
          "priority" => "medium",
          "due_date" => "",
          "goal_slug" => "",
          "kanban_status" => "backlog"
        })
        |> render_submit()

      # Success flash (localized)
      assert html =~ t("Todo created.")

      # Form closes after create
      refute has_element?(view, "#kanban-quick-add")

      # The todo was persisted as a note with kind:todo and kanban_status column.
      todo =
        Brain.list_todos(workspace_id: context.id, limit: 500)
        |> Enum.find(fn p -> p.title == "Quick Add Test Todo" end)

      assert todo != nil
      assert todo.page_type == "note"
      assert todo.kanban_status == "backlog"
      assert todo.priority == "medium"
      assert get_in(todo.meta, ["goal_slug"]) in [nil, ""]
    end

    test "with ?goal=<slug> filter active, created todo carries goal_slug", %{
      conn: conn,
      context: context,
      goal: goal
    } do
      {:ok, view, _html} = live(conn, ~p"/panel/kanban?goal=#{goal.slug}")

      # The goal filter is active
      assert has_element?(view, "#filter-goal")

      # Open the quick-add form
      view |> element("button", t("Nueva tarea")) |> render_click()
      assert has_element?(view, "#kanban-quick-add")

      # The goal select should default to the filtered goal slug
      assert has_element?(
               view,
               ~s(#kanban-quick-add option[value="#{goal.slug}"][selected])
             )

      html =
        view
        |> form("#kanban-quick-add", %{
          "title" => "Filtered Goal Todo",
          "priority" => "medium",
          "due_date" => "",
          "goal_slug" => goal.slug,
          "kanban_status" => "backlog"
        })
        |> render_submit()

      assert html =~ t("Todo created.")

      todo =
        Brain.list_todos(workspace_id: context.id, limit: 500)
        |> Enum.find(fn p -> p.title == "Filtered Goal Todo" end)

      assert todo != nil
      assert get_in(todo.meta, ["goal_slug"]) == goal.slug
    end

    test "board renders the newly created todo in the backlog column", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/panel/kanban")

      view |> element("button", t("Nueva tarea")) |> render_click()

      view
      |> form("#kanban-quick-add", %{
        "title" => "Board Render Test Todo",
        "priority" => "medium",
        "due_date" => "",
        "goal_slug" => "",
        "kanban_status" => "backlog"
      })
      |> render_submit()

      html = render(view)

      backlog_column =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-kanban-status="backlog"]))

      assert LazyHTML.text(backlog_column) =~ "Board Render Test Todo"
    end
  end

  describe "card archive button" do
    test "archives the todo from its card and removes it from the board", %{
      conn: conn,
      context: context
    } do
      {:ok, todo} =
        Brain.create_page(%{
          workspace_id: context.id,
          title: "Todo To Archive",
          page_type: "note",
          meta: %{"kind" => "todo"},
          kanban_status: "backlog"
        })

      {:ok, view, _html} = live(conn, ~p"/panel/kanban")

      # The card renders with its archive button (bottom-right of the card)
      assert has_element?(view, ~s(button[phx-value-slug="#{todo.slug}"]))

      view
      |> element(~s(button[phx-value-slug="#{todo.slug}"]))
      |> render_click()

      assert Brain.get_page_by_slug(todo.slug, context.id).archived == true

      # The card disappears from the board after re-render
      refute has_element?(view, ~s(button[phx-value-slug="#{todo.slug}"]))
    end
  end
end
