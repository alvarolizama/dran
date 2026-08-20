defmodule DranWeb.HomeLiveTest do
  use DranWeb.ConnCase, async: false

  alias Dran.Knowledge

  alias Dran.Goals

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

    {:ok, wiki_ctx} = Knowledge.create_workspace(%{name: "Wiki Test", slug: "wiki-test"})

    {:ok, page} =
      Knowledge.create_page(%{
        workspace_id: wiki_ctx.id,
        title: "Wiki Test Note",
        body: "A note visible through the wiki",
        page_type: "note"
      })

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user, "test_user")
      |> Plug.Conn.put_session(:workspace_slug, "personal")

    {:ok, conn: conn, wiki_ctx: wiki_ctx, page: page}
  end

  describe "wiki at root" do
    test "GET / renders the home index listing accessible workspaces", %{
      conn: conn,
      wiki_ctx: wiki_ctx
    } do
      {:ok, _view, html} = live(conn, ~p"/")

      # All workspaces the user can access are shown (personal is default)
      assert html =~ "Personal"
    end

    test "GET /:workspace_slug renders the context home when wiki is enabled", %{
      conn: conn,
      wiki_ctx: wiki_ctx
    } do
      {:ok, _view, html} = live(conn, ~p"/#{wiki_ctx.slug}")

      assert html =~ wiki_ctx.name
    end

    test "GET /:workspace_slug/type/:page_type/:slug renders the page read-only", %{
      conn: conn,
      wiki_ctx: wiki_ctx,
      page: page
    } do
      {:ok, _view, html} = live(conn, ~p"/#{wiki_ctx.slug}/type/note/#{page.slug}")

      assert html =~ "Wiki Test Note"
      assert html =~ "A note visible through the wiki"
    end

    test "GET /:unknown_slug redirects to / for an unknown workspace", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/no-such-workspace")
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

  describe "todo kanban + type_list" do
    setup %{wiki_ctx: wiki_ctx} do
      {:ok, project} =
        Knowledge.create_page(%{
          workspace_id: wiki_ctx.id,
          title: "Alpha Project",
          slug: "alpha-project",
          page_type: "note",
          meta: %{"kind" => "project"}
        })

      {:ok, goal} =
        Goals.create_goal(%{
          workspace_id: wiki_ctx.id,
          title: "Beta Goal",
          slug: "beta-goal"
        })

      {:ok, plan} =
        Knowledge.create_page(%{
          workspace_id: wiki_ctx.id,
          title: "Gamma Plan",
          slug: "gamma-plan",
          page_type: "note",
          meta: %{"kind" => "plan"}
        })

      {:ok, linked} =
        Knowledge.create_page(%{
          workspace_id: wiki_ctx.id,
          title: "Linked Todo",
          slug: "linked-todo",
          page_type: "note",
          meta: %{"kind" => "todo"},
          kanban_status: "in_progress"
        })

      {:ok, orphan} =
        Knowledge.create_page(%{
          workspace_id: wiki_ctx.id,
          title: "Orphan Todo",
          slug: "orphan-todo",
          page_type: "note",
          meta: %{"kind" => "todo"},
          kanban_status: "backlog"
        })

      %{
        project: project,
        goal: goal,
        plan: plan,
        linked: linked,
        orphan: orphan
      }
    end

    test "wiki kanban renders both todos grouped by status", %{
      conn: conn,
      wiki_ctx: wiki_ctx
    } do
      {:ok, _view, html} = live(conn, ~p"/#{wiki_ctx.slug}/kanban")

      assert html =~ "Linked Todo"
      assert html =~ "Orphan Todo"

      # Kanban column headers
      assert html =~ "In Progress"
      assert html =~ "Backlog"

      # Goals/projects/plans are separate tables — not on the kanban board
      refute html =~ "Alpha Project"
      refute html =~ "Beta Goal"
      refute html =~ "Gamma Plan"
    end

    test "wiki todo type_list renders both todos", %{
      conn: conn,
      wiki_ctx: wiki_ctx
    } do
      {:ok, _view, html} = live(conn, ~p"/#{wiki_ctx.slug}/type/todo")

      assert html =~ "Linked Todo"
      assert html =~ "Orphan Todo"

      # Grouped under kanban status headings (localized)
      assert html =~ "En progreso"
      assert html =~ "Pendientes"
    end
  end

  describe "todo kanban statuses" do
    setup %{wiki_ctx: wiki_ctx} do
      {:ok, done_todo} =
        Knowledge.create_page(%{
          workspace_id: wiki_ctx.id,
          title: "Done Todo",
          slug: "done-todo",
          page_type: "note",
          meta: %{"kind" => "todo"},
          kanban_status: "done"
        })

      {:ok, cancelled_todo} =
        Knowledge.create_page(%{
          workspace_id: wiki_ctx.id,
          title: "Cancelled Todo",
          slug: "cancelled-todo",
          page_type: "note",
          meta: %{"kind" => "todo"},
          kanban_status: "cancelled"
        })

      %{done_todo: done_todo, cancelled_todo: cancelled_todo}
    end

    test "wiki kanban places todos in their status columns", %{
      conn: conn,
      wiki_ctx: wiki_ctx
    } do
      {:ok, _view, html} = live(conn, ~p"/#{wiki_ctx.slug}/kanban")

      assert html =~ "Done Todo"
      assert html =~ "Cancelled Todo"
      assert html =~ "Done"
      assert html =~ "Cancelled"
    end
  end
end
