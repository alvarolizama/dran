defmodule DranWeb.GoalLiveTest do
  use DranWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Dran.{Executions, Goals, Knowledge, Workflows}

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
    test "renders the goal detail", %{conn: conn, ws: ws, goal: goal} do
      {:ok, _view, html} = live(conn, ~p"/#{ws.slug}/goals/#{goal.slug}")

      assert html =~ "Learn Elixir"
    end

    test "header shows created/updated dates and graph link", %{conn: conn, ws: ws, goal: goal} do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/goals/#{goal.slug}")

      assert has_element?(view, "a[href='#{~p"/#{ws.slug}/graph"}']", t("Graph"))
      assert render(view) =~ t("Created")
      assert render(view) =~ t("Updated")
    end

    test "archive/unarchive toggles the goal", %{conn: conn, ws: ws, goal: goal} do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/goals/#{goal.slug}")

      view
      |> element("button[phx-click='archive_goal']")
      |> render_click()

      assert render(view) =~ t("Unarchive")
      assert Goals.get_goal(goal.id).archived

      view
      |> element("button[phx-click='unarchive_goal']")
      |> render_click()

      refute render(view) =~ t("Unarchive")
      refute Goals.get_goal(goal.id).archived
    end

    test "pin/unpin toggles the goal", %{conn: conn, ws: ws, goal: goal} do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/goals/#{goal.slug}")

      view
      |> element("button[phx-click='toggle_pinned_goal']")
      |> render_click()

      assert render(view) =~ t("Unpin")
      assert Goals.get_goal(goal.id).pinned

      view
      |> element("button[phx-click='toggle_pinned_goal']")
      |> render_click()

      assert render(view) =~ t("Pin")
      refute Goals.get_goal(goal.id).pinned
    end

    test "delete removes the goal and navigates to the index", %{conn: conn, ws: ws, goal: goal} do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/goals/#{goal.slug}")

      view
      |> element("button[phx-click='delete']")
      |> render_click()

      refute Goals.get_goal(goal.id)
      assert_redirect(view, ~p"/#{ws.slug}/goals")
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

      # Auto-managed slug: renaming the title regenerates the slug.
      updated = Dran.Goals.get_goal_by_slug("renamed-goal", ws.id)
      assert updated.title == "Renamed goal"
      assert updated.status == "on_hold"
      refute Dran.Goals.get_goal_by_slug(goal.slug, ws.id)

      # Renaming redirects (push_navigate) — the original view is dead, so we
      # only assert the DB outcome, not elements on the terminated process.
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

  describe "checklist (sidebar)" do
    test "renders an empty checklist block with the add form", %{conn: conn, ws: ws, goal: goal} do
      {:ok, view, html} = live(conn, ~p"/#{ws.slug}/goals/#{goal.slug}")

      assert has_element?(view, "#goal-checklist")
      assert has_element?(view, "#goal-checklist-form")
      assert html =~ "Sin ítems todavía."
    end

    test "adds, toggles and removes items", %{conn: conn, ws: ws, goal: goal} do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/goals/#{goal.slug}")

      view
      |> element("#goal-checklist-form")
      |> render_submit(%{checklist: %{text: "Primer paso"}})

      assert render(view) =~ "Primer paso"
      assert render(view) =~ "0/1"

      view
      |> element("#goal-checklist-item-0 button[phx-click='toggle_checklist_item']")
      |> render_click()

      assert render(view) =~ "1/1"
      assert render(view) =~ "line-through"

      view
      |> element("#goal-checklist-item-0 button[phx-click='remove_checklist_item']")
      |> render_click()

      refute render(view) =~ "Primer paso"
    end
  end
end
