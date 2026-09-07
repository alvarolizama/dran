defmodule DranWeb.ClusterLiveTest do
  use DranWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Dran.Graph.ClusterSummary
  alias Dran.Knowledge
  alias Dran.Repo

  setup do
    {:ok, ws} = Knowledge.create_workspace(%{name: "Cluster Test", slug: "cluster-test"})

    {:ok, summary} =
      Repo.insert(%ClusterSummary{
        workspace_id: ws.id,
        cluster_id: 7,
        summary: "Cluster of 2 pages",
        page_count: 2,
        top_pages: [
          %{"slug" => "page-one", "title" => "Page One", "pagerank" => 0.1},
          %{"slug" => "page-two", "title" => "Page Two", "pagerank" => 0.05}
        ],
        generated_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    {:ok, page} =
      Knowledge.create_page(%{
        "workspace_id" => ws.id,
        "title" => "Page One",
        "slug" => "page-one",
        "page_type" => "note",
        "content" => "hola",
        "meta" => %{"cluster_id" => 7}
      })

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user, "test_user")
      |> Plug.Conn.put_session(:workspace_slug, ws.slug)
      |> Plug.Conn.put_session(:is_owner, true)

    {:ok, conn: conn, ws: ws, summary: summary, page: page}
  end

  describe "index" do
    test "lists cluster summaries", %{conn: conn, ws: ws} do
      {:ok, _view, html} = live(conn, ~p"/#{ws.slug}/clusters")

      assert html =~ "Cluster"
      assert html =~ "Cluster of 2 pages"
    end
  end

  describe "show" do
    # Regression: the <.show_view> function component only sees assigns it is
    # explicitly given; missing :workspace_slug crashed the render with
    # KeyError on /clusters/:id (2026-09).
    test "renders summary, top pages and member pages", %{conn: conn, ws: ws} do
      {:ok, _view, html} = live(conn, ~p"/#{ws.slug}/clusters/7")

      assert html =~ "Cluster of 2 pages"
      assert html =~ "Page One"
      assert html =~ "Page Two"
    end

    test "renders not-found state for unknown cluster", %{conn: conn, ws: ws} do
      {:ok, _view, html} = live(conn, ~p"/#{ws.slug}/clusters/999")

      assert html =~ Gettext.gettext(DranWeb.Gettext, "Cluster not found")
    end

    test "clicking an index card round-trips without crashing", %{
      conn: conn,
      ws: ws
    } do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/clusters")

      assert has_element?(view, ~S|div[phx-value-id="7"]|)

      # push_navigate to the show route — must not raise. The KeyError crash
      # happened rendering the *target*, covered by the show tests above.
      render_click(view, "show_cluster", %{"id" => "7"})
    end

    # Regression: page links were built without the /:workspace_slug prefix,
    # so clicking a member page pushed to a dead /notes/... route.
    test "member page link navigates to the workspace-scoped show route", %{
      conn: conn,
      ws: ws,
      page: page
    } do
      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/clusters/7")

      render_click(view, "show_page", %{"slug" => page.slug, "type" => page.page_type})

      assert_redirect(view, "/#{ws.slug}/notes/page-one")
    end
  end
end
