defmodule DranWeb.GoalLiveTest do
  use DranWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Dran.{Executions, Goals, Knowledge, Tasks, Workflows}

  defp t(msgid), do: Gettext.gettext(DranWeb.Gettext, msgid)

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

    {:ok, ws} = Knowledge.create_workspace(%{name: "Goal Test", slug: "goal-test"})

    {:ok, goal} =
      Goals.create_goal(%{
        "workspace_id" => ws.id,
        "title" => "Learn Elixir",
        "slug" => "learn-elixir"
      })

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user, "test_user")
      |> Plug.Conn.put_session(:workspace_slug, ws.slug)
      |> Plug.Conn.put_session(:is_owner, true)

    {:ok, conn: conn, ws: ws, goal: goal}
  end

  describe "show" do
    test "renders the goal with no linked tasks", %{conn: conn, ws: ws, goal: goal} do
      {:ok, _view, html} = live(conn, ~p"/#{ws.slug}/goals/#{goal.slug}")

      assert html =~ "Learn Elixir"
      refute html =~ t("Linked tasks")
    end

    test "lists tasks linked via part_of", %{conn: conn, ws: ws, goal: goal} do
      {:ok, task} =
        Tasks.create_task(%{
          "workspace_id" => ws.id,
          "title" => "Read the book",
          "status" => "in_progress"
        })

      {:ok, _} = Tasks.link_to_goal(task, goal)

      {:ok, _view, html} = live(conn, ~p"/#{ws.slug}/goals/#{goal.slug}")

      assert html =~ t("Linked tasks")
      assert html =~ "Read the book"
    end

    test "done tasks render struck through", %{conn: conn, ws: ws, goal: goal} do
      {:ok, task} =
        Tasks.create_task(%{"workspace_id" => ws.id, "title" => "Finished", "status" => "done"})

      {:ok, _} = Tasks.link_to_goal(task, goal)

      {:ok, _view, html} = live(conn, ~p"/#{ws.slug}/goals/#{goal.slug}")

      assert html =~ "Finished"
      assert html =~ "line-through"
    end

    test "shows a link to the task board", %{conn: conn, ws: ws, goal: goal} do
      {:ok, _view, html} = live(conn, ~p"/#{ws.slug}/goals/#{goal.slug}")

      assert html =~ ~s(href="/#{ws.slug}/tasks")
    end

    test "refreshes linked tasks on a task_changed broadcast", %{conn: conn, ws: ws, goal: goal} do
      {:ok, task} = Tasks.create_task(%{"workspace_id" => ws.id, "title" => "Live added"})

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/goals/#{goal.slug}")
      refute render(view) =~ "Live added"

      # link_to_goal triggers the real broadcast_task_change on the
      # workspace topic — the exact production path, no manual broadcast.
      {:ok, _} = Tasks.link_to_goal(task, goal)

      assert render(view) =~ "Live added"
    end
  end

  describe "linked workflows" do
    test "lists workflows whose goal_id points at the goal, with links", %{
      conn: conn,
      ws: ws,
      goal: goal
    } do
      {:ok, workflow} =
        Workflows.create_workflow(%{
          "workspace_id" => ws.id,
          "goal_id" => goal.id,
          "title" => "Deploy pipeline",
          "slug" => "deploy-pipeline"
        })

      {:ok, view, html} = live(conn, ~p"/#{ws.slug}/goals/#{goal.slug}")

      assert html =~ t("Workflows vinculados")
      assert html =~ "Deploy pipeline"
      assert has_element?(view, "#goal-workflows")
      assert html =~ ~s(href="/#{ws.slug}/workflows/#{workflow.slug}")
    end

    test "renders no linked-workflows section when the goal has none", %{
      conn: conn,
      ws: ws,
      goal: goal
    } do
      {:ok, _view, html} = live(conn, ~p"/#{ws.slug}/goals/#{goal.slug}")

      refute html =~ t("Workflows vinculados")
    end

    test "refreshes the list on a session_changed broadcast", %{conn: conn, ws: ws, goal: goal} do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/goals/#{goal.slug}")

      # Created AFTER mount — invisible until a broadcast forces a re-query.
      {:ok, workflow} =
        Workflows.create_workflow(%{
          "workspace_id" => ws.id,
          "goal_id" => goal.id,
          "title" => "Late workflow",
          "slug" => "late-workflow"
        })

      {:ok, _} = Workflows.create_step(workflow, %{"title" => "Only", "slug" => "only"})

      refute render(view) =~ "Late workflow"

      # open_session broadcasts {:session_changed, :opened, session} on the
      # workspace topic — the exact production path.
      {:ok, _} = Executions.open_session(workflow)

      assert render(view) =~ "Late workflow"
    end
  end

  describe "tiptap body editor (shared resource pattern)" do
    test "edit modal renders the Tiptap editor mount for the goal body", %{
      conn: conn,
      ws: ws,
      goal: goal
    } do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/goals/#{goal.slug}?edit=true")

      assert has_element?(view, "#goal-editor-modal-#{goal.id}[phx-hook='MarkdownEditor']")
    end

    test "new modal renders the Tiptap editor for the goal body", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/goals?new=true")

      assert has_element?(view, "#goal-editor-modal-new[phx-hook='MarkdownEditor']")
    end

    test "creating a goal with a body persists it", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/goals?new=true")

      view
      |> form("#goal-modal-form")
      |> render_submit(%{
        "goal" => %{
          "title" => "Goal with body",
          "body" => "# Hola\n\n```mermaid\ngraph TD\nA-->B\n```"
        }
      })

      goal = Dran.Goals.get_goal_by_slug("goal-with-body", ws.id)
      assert goal.body =~ "mermaid"
    end
  end

  describe "goal resource modal" do
    test "?new=true opens the create modal over the index", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/goals?new=true")

      assert has_element?(view, "#goal-resource-modal")
      assert has_element?(view, "#goal-modal-form")
      assert has_element?(view, "#goal-resource-modal button[form='goal-modal-form']")
      # Editor without toolbar (approved mockup)
      refute has_element?(view, "#goal-resource-modal [data-testid='editor-toolbar']")
    end

    test "?edit=true opens the edit modal over the detail", %{conn: conn, ws: ws, goal: goal} do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/goals/#{goal.slug}?edit=true")

      assert has_element?(view, "#goal-resource-modal")
      assert has_element?(view, "#goal-modal-form input[name='goal[title]']")
    end

    test "saving from the create modal persists and closes to the list", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/goals?new=true")

      view
      |> form("#goal-modal-form")
      |> render_submit(%{"goal" => %{"title" => "Modal created goal", "status" => "draft"}})

      created = Dran.Goals.get_goal_by_slug("modal-created-goal", ws.id)
      assert created
      assert created.status == "draft"
      assert created.workspace_id == ws.id

      refute has_element?(view, "#goal-resource-modal")
    end

    test "saving from the edit modal updates fields and closes to the detail", %{
      conn: conn,
      ws: ws,
      goal: goal
    } do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/goals/#{goal.slug}?edit=true")

      view
      |> form("#goal-modal-form")
      |> render_submit(%{"goal" => %{"title" => "Renamed goal", "status" => "on_hold"}})

      updated = Dran.Goals.get_goal_by_slug(goal.slug, ws.id)
      assert updated.title == "Renamed goal"
      assert updated.status == "on_hold"

      refute has_element?(view, "#goal-resource-modal")
    end

    test "close_goal_modal patches back to the detail page", %{conn: conn, ws: ws, goal: goal} do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/goals/#{goal.slug}?edit=true")

      render_click(view, "close_goal_modal", %{})

      refute has_element?(view, "#goal-resource-modal")
    end

    test "empty title keeps the modal open", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/goals?new=true")

      view
      |> form("#goal-modal-form")
      |> render_submit(%{"goal" => %{"title" => ""}})

      assert has_element?(view, "#goal-resource-modal")
    end

    test "forged workspace_id/created_by in params is ignored (server-owned whitelist)", %{
      conn: conn,
      ws: ws
    } do
      {:ok, other} =
        Dran.Knowledge.create_workspace(%{
          name: "Other Goal #{System.unique_integer([:positive])}",
          slug: "other-goal-#{System.unique_integer([:positive])}"
        })

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/goals?new=true")

      view
      |> form("#goal-modal-form")
      |> render_submit(%{
        "goal" => %{
          "title" => "Goal no forgeable",
          # Forge attempts — must be ignored (server owns them)
          "workspace_id" => other.id,
          "created_by" => "evil_agent",
          "parent_goal_id" => other.id,
          "archived" => "true"
        }
      })

      created = Dran.Goals.get_goal_by_slug("goal-no-forgeable", ws.id)
      assert created, "goal should have been created in the REAL workspace"
      assert created.workspace_id == ws.id
      assert created.created_by == "test_user"
      refute created.archived
    end
  end
end
