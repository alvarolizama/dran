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

    test "renders the section with empty state and picker when the goal has none", %{
      conn: conn,
      ws: ws,
      goal: goal
    } do
      {:ok, view, html} = live(conn, ~p"/#{ws.slug}/goals/#{goal.slug}")

      # Section is always present — the picker survives an empty list.
      assert has_element?(view, "#goal-workflows")
      assert html =~ t("Sin workflows vinculados.")
      assert has_element?(view, "form[phx-change='search_linkable_workflows']")
    end

    test "attach/detach round-trip via the picker", %{
      conn: conn,
      ws: ws,
      goal: goal
    } do
      {:ok, workflow} =
        Workflows.create_workflow(%{
          "workspace_id" => ws.id,
          "title" => "Deploy pipeline",
          "slug" => "deploy-pipeline",
          "status" => "active"
        })

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/goals/#{goal.slug}")

      # Attach from the picker
      view
      |> element("button[phx-click='attach_workflow'][phx-value-workflow-id='#{workflow.id}']")
      |> render_click()

      assert has_element?(view, "#goal-workflows", "Deploy pipeline")
      assert Workflows.get_workflow!(workflow.id).goal_id == goal.id

      # Detach — the section (and picker) must survive the empty list
      view
      |> element("button[phx-click='detach_workflow'][phx-value-workflow-id='#{workflow.id}']")
      |> render_click()

      assert has_element?(view, "#goal-workflows")
      assert render(view) =~ t("Sin workflows vinculados.")
      assert has_element?(view, "button[phx-click='attach_workflow']")
      assert Workflows.get_workflow!(workflow.id).goal_id == nil
    end
  end

  describe "linked notes (part_of relations)" do
    setup %{ws: ws} do
      {:ok, plan_note} =
        Knowledge.create_page(%{
          workspace_id: ws.id,
          title: "Q4 Launch Plan",
          slug: "q4-launch-plan",
          body: "The plan",
          page_type: "note",
          meta: %{"kind" => "plan"}
        })

      {:ok, project_note} =
        Knowledge.create_page(%{
          workspace_id: ws.id,
          title: "Website Redesign",
          slug: "website-redesign",
          body: "The project",
          page_type: "note",
          meta: %{"kind" => "project"}
        })

      %{plan_note: plan_note, project_note: project_note}
    end

    test "empty state renders when no notes are linked", %{conn: conn, ws: ws, goal: goal} do
      {:ok, view, html} = live(conn, ~p"/#{ws.slug}/goals/#{goal.slug}")

      assert has_element?(view, "#goal-linked-notes")
      assert html =~ t("Sin notas vinculadas.")
    end

    test "link_note links a plan/project note via part_of relation", %{
      conn: conn,
      ws: ws,
      goal: goal,
      plan_note: plan_note,
      project_note: project_note
    } do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/goals/#{goal.slug}")

      # Empty query: both linkable notes appear, grouped by kind.
      assert render(view) =~ "Q4 Launch Plan"
      assert render(view) =~ "Website Redesign"

      # Typing filters server-side.
      view |> render_change("search_linkable_notes", %{"q" => "website"})
      assert render(view) =~ "Website Redesign"
      refute render(view) =~ "Q4 Launch Plan"

      view
      |> element("button[phx-click='link_note'][phx-value-page-id='#{project_note.id}']")
      |> render_click()

      assert has_element?(view, "#goal-linked-note-#{project_note.id}")
      assert Dran.Goals.linked_notes(goal) |> Enum.map(& &1.page.id) == [project_note.id]
    end

    test "unlink_note removes the relation", %{
      conn: conn,
      ws: ws,
      goal: goal,
      project_note: project_note
    } do
      Dran.Goals.link_note(goal, project_note)

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/goals/#{goal.slug}")

      assert has_element?(view, "#goal-linked-note-#{project_note.id}")

      view
      |> element("button[phx-click='unlink_note'][phx-value-page-id='#{project_note.id}']")
      |> render_click()

      refute has_element?(view, "#goal-linked-note-#{project_note.id}")
      assert Dran.Goals.linked_notes(goal) == []
    end

    test "archive_linked_note archives the page", %{
      conn: conn,
      ws: ws,
      goal: goal,
      plan_note: plan_note
    } do
      Dran.Goals.link_note(goal, plan_note)

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/goals/#{goal.slug}")

      view
      |> element("button[phx-click='archive_linked_note'][phx-value-page-id='#{plan_note.id}']")
      |> render_click()

      refute has_element?(view, "#goal-linked-note-#{plan_note.id}")
      page = Knowledge.get_page(plan_note.id)
      assert page.archived
    end
  end

  describe "session broadcast sync" do
    test "refreshes the list on a session_changed broadcast", %{conn: conn, ws: ws, goal: goal} do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/goals/#{goal.slug}")

      # Created AFTER mount — invisible until a broadcast forces a re-query.
      {:ok, workflow} =
        Workflows.create_workflow(%{
          "workspace_id" => ws.id,
          "goal_id" => goal.id,
          "title" => "Late workflow",
          "slug" => "late-workflow",
          "status" => "active"
        })

      {:ok, _} = Workflows.create_step(workflow, %{"title" => "Only", "slug" => "only"})

      refute render(view) =~ "Late workflow"

      # open_session broadcasts {:session_changed, :opened, session} on the
      # workspace topic — the exact production path.
      {:ok, _} = Executions.open_session(workflow)

      assert render(view) =~ "Late workflow"
    end
  end

  describe "draft workflows cannot open sessions (live)" do
    test "show page hides the Nueva sesión button for a draft workflow", %{
      conn: conn,
      ws: ws,
      goal: goal
    } do
      {:ok, workflow} =
        Workflows.create_workflow(%{
          "workspace_id" => ws.id,
          "goal_id" => goal.id,
          "title" => "Draft pipeline",
          "slug" => "draft-pipeline",
          "status" => "draft"
        })

      {:ok, _} = Workflows.create_step(workflow, %{"title" => "Only", "slug" => "only"})

      {:ok, view, html} = live(conn, ~p"/#{ws.slug}/workflows/#{workflow.slug}")

      refute has_element?(view, "#workflow-session-form")
      refute html =~ "Nueva sesión"
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
