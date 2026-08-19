defmodule DranWeb.WikiLiveTest do
  use DranWeb.ConnCase, async: false

  alias Dran.Brain

  # The wiki lives at the ROOT of the app — `/` is the first thing a
  # logged-in user sees. Admin/data views live under /panel.

  setup %{conn: conn} do
    # Disable inference scheduling so create_page doesn't call external APIs
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

    {:ok, wiki_ctx} = Brain.create_context(%{name: "Wiki Test", slug: "wiki-test"})
    {:ok, wiki_ctx} = Brain.update_context_settings(wiki_ctx, %{wiki_enabled: true})

    {:ok, page} =
      Brain.create_page(%{
        context_id: wiki_ctx.id,
        title: "Wiki Test Note",
        body: "A note visible through the wiki",
        page_type: "note"
      })

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user, "test_user")
      |> Plug.Conn.put_session(:context_slug, "personal")

    {:ok, conn: conn, wiki_ctx: wiki_ctx, page: page}
  end

  describe "wiki at root" do
    test "GET / renders the wiki index listing wiki-enabled contexts", %{
      conn: conn,
      wiki_ctx: wiki_ctx
    } do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ wiki_ctx.name
    end

    test "GET /:context_slug renders the context home when wiki is enabled", %{
      conn: conn,
      wiki_ctx: wiki_ctx
    } do
      {:ok, _view, html} = live(conn, ~p"/#{wiki_ctx.slug}")

      assert html =~ wiki_ctx.name
    end

    test "GET /:context_slug/type/:page_type/:slug renders the page read-only", %{
      conn: conn,
      wiki_ctx: wiki_ctx,
      page: page
    } do
      {:ok, _view, html} = live(conn, ~p"/#{wiki_ctx.slug}/type/note/#{page.slug}")

      assert html =~ "Wiki Test Note"
      assert html =~ "A note visible through the wiki"
    end

    test "GET /:context_slug redirects to / when the wiki is not enabled", %{conn: conn} do
      # "personal" exists but has no wiki_enabled flag
      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/personal")
    end

    test "GET /:unknown_slug redirects to / for an unknown context", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/no-such-context")
    end
  end

  describe "authentication" do
    test "GET / redirects to /login without a session" do
      conn = build_conn() |> get(~p"/")
      assert redirected_to(conn) == ~p"/login"
    end

    test "GET /panel redirects to /login without a session" do
      conn = build_conn() |> get(~p"/panel")
      assert redirected_to(conn) == ~p"/login"
    end
  end

  describe "todo filters (kanban + type_list)" do
    setup %{wiki_ctx: wiki_ctx} do
      {:ok, project} =
        Brain.create_page(%{
          context_id: wiki_ctx.id,
          title: "Alpha Project",
          page_type: "project"
        })

      {:ok, goal} =
        Brain.create_page(%{
          context_id: wiki_ctx.id,
          title: "Beta Goal",
          page_type: "goal"
        })

      {:ok, plan} =
        Brain.create_page(%{
          context_id: wiki_ctx.id,
          title: "Gamma Plan",
          page_type: "plan"
        })

      {:ok, linked} =
        Brain.create_page(%{
          context_id: wiki_ctx.id,
          title: "Linked Todo",
          page_type: "todo",
          meta: %{
            "kanban_status" => "in_progress",
            "project_slug" => project.slug,
            "goal_slug" => goal.slug
          }
        })

      {:ok, orphan} =
        Brain.create_page(%{
          context_id: wiki_ctx.id,
          title: "Orphan Todo",
          page_type: "todo",
          meta: %{"kanban_status" => "backlog"}
        })

      %{
        project: project,
        goal: goal,
        plan: plan,
        linked: linked,
        orphan: orphan
      }
    end

    test "wiki kanban renders the filter bar and both todos", %{
      conn: conn,
      wiki_ctx: wiki_ctx
    } do
      {:ok, _view, html} = live(conn, ~p"/#{wiki_ctx.slug}/kanban")

      assert html =~ "Alpha Project"
      assert html =~ "Beta Goal"
      assert html =~ "Gamma Plan"
      assert html =~ "Linked Todo"
      assert html =~ "Orphan Todo"
    end

    test "wiki kanban filter_project narrows the board to the linked todo", %{
      conn: conn,
      wiki_ctx: wiki_ctx,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/#{wiki_ctx.slug}/kanban")

      html =
        view
        |> element(~s{select#wiki-filter-project})
        |> render_change(%{"value" => project.slug})

      assert html =~ "Linked Todo"
      refute html =~ "Orphan Todo"
    end

    test "wiki kanban clear_filters restores the full board", %{
      conn: conn,
      wiki_ctx: wiki_ctx,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/#{wiki_ctx.slug}/kanban")

      html =
        view
        |> element(~s{select#wiki-filter-project})
        |> render_change(%{"value" => project.slug})

      assert html =~ "Linked Todo"
      refute html =~ "Orphan Todo"

      html = render_click(view, :clear_filters)

      assert html =~ "Linked Todo"
      assert html =~ "Orphan Todo"
    end

    test "wiki todo type_list filter_plan narrows the list", %{
      conn: conn,
      wiki_ctx: wiki_ctx,
      plan: plan
    } do
      {:ok, view, _html} = live(conn, ~p"/#{wiki_ctx.slug}/type/todo")

      html =
        view
        |> element(~s{select#wiki-todo-filter-plan})
        |> render_change(%{"value" => plan.slug})

      # Neither todo carries plan_slug — both should be filtered out
      refute html =~ "Linked Todo"
      refute html =~ "Orphan Todo"
    end

    test "wiki todo type_list 'none' filter shows only orphans", %{
      conn: conn,
      wiki_ctx: wiki_ctx
    } do
      {:ok, view, _html} = live(conn, ~p"/#{wiki_ctx.slug}/type/todo")

      html =
        view
        |> element(~s{select#wiki-todo-filter-project})
        |> render_change(%{"value" => "none"})

      assert html =~ "Orphan Todo"
      refute html =~ "Linked Todo"
    end
  end

  describe "todo badges (project/goal/plan labels)" do
    setup %{wiki_ctx: wiki_ctx} do
      {:ok, project} =
        Brain.create_page(%{
          context_id: wiki_ctx.id,
          title: "Badge Project",
          page_type: "project"
        })

      {:ok, goal} =
        Brain.create_page(%{
          context_id: wiki_ctx.id,
          title: "Badge Goal",
          page_type: "goal"
        })

      {:ok, _plan} =
        Brain.create_page(%{
          context_id: wiki_ctx.id,
          title: "Badge Plan",
          page_type: "plan"
        })

      {:ok, linked_todo} =
        Brain.create_page(%{
          context_id: wiki_ctx.id,
          title: "Badge Test Todo",
          page_type: "todo",
          meta: %{
            "kanban_status" => "in_progress",
            "project_slug" => project.slug,
            "goal_slug" => goal.slug
          }
        })

      %{
        project: project,
        goal: goal,
        linked_todo: linked_todo
      }
    end

    test "wiki kanban shows project and goal badge labels on todo cards", %{
      conn: conn,
      wiki_ctx: wiki_ctx
    } do
      {:ok, _view, html} = live(conn, ~p"/#{wiki_ctx.slug}/kanban")

      assert html =~ "Badge Test Todo"
      assert html =~ "Badge Project"
      assert html =~ "Badge Goal"
    end

    test "wiki todo type_list shows project and goal badge labels on todo rows", %{
      conn: conn,
      wiki_ctx: wiki_ctx
    } do
      {:ok, _view, html} = live(conn, ~p"/#{wiki_ctx.slug}/type/todo")

      assert html =~ "Badge Test Todo"
      assert html =~ "Badge Project"
      assert html =~ "Badge Goal"
    end
  end
end
