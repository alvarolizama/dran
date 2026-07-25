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

    context = Brain.get_context_by_slug("personal")

    # A goal page so the goal-filter test has a real slug to use.
    {:ok, goal} =
      Brain.create_page(%{
        context_id: context.id,
        title: "Kanban Test Goal",
        page_type: "goal"
      })

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user, "test_user")
      |> Plug.Conn.put_session(:context_slug, "personal")

    {:ok, conn: conn, context: context, goal: goal}
  end

  describe "quick-add form" do
    test "creates a todo in backlog with default priority medium", %{
      conn: conn,
      context: context
    } do
      {:ok, view, _html} = live(conn, ~p"/kanban")

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

      # The todo was persisted with the expected meta. Find by title since
      # Slug.generate appends a uniqueness suffix when re-run after create.
      todo =
        Brain.list_pages(context_id: context.id, type: "todo", limit: 500)
        |> Enum.find(fn p -> p.title == "Quick Add Test Todo" end)

      assert todo != nil
      assert todo.page_type == "todo"
      assert todo.meta["kanban_status"] == "backlog"
      assert todo.meta["priority"] == "medium"
      assert todo.meta["goal_slug"] in [nil, ""]
    end

    test "with ?goal=<slug> filter active, created todo carries goal_slug", %{
      conn: conn,
      context: context,
      goal: goal
    } do
      {:ok, view, _html} = live(conn, ~p"/kanban?goal=#{goal.slug}")

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
        Brain.list_pages(context_id: context.id, type: "todo", limit: 500)
        |> Enum.find(fn p -> p.title == "Filtered Goal Todo" end)

      assert todo != nil
      assert todo.meta["goal_slug"] == goal.slug
    end

    test "board renders the newly created todo in the backlog column", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/kanban")

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
end
