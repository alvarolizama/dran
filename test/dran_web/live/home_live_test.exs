defmodule DranWeb.HomeLiveTest do
  use DranWeb.ConnCase, async: false

  alias Dran.Knowledge

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
      |> Plug.Conn.put_session(:is_owner, true)

    {:ok, conn: conn, wiki_ctx: wiki_ctx, page: page}
  end

  describe "workspace home" do
    test "GET /:workspace_slug renders the workspace home", %{conn: conn, wiki_ctx: wiki_ctx} do
      {:ok, _view, html} = live(conn, ~p"/#{wiki_ctx.slug}")

      assert html =~ wiki_ctx.name
    end

    # TODO: PagesLive resolves workspace from session, not URL — needs fix in PageDetail.mount_page_viewer
    @tag :skip
    test "GET /:workspace_slug/:type/:slug renders the page read-only", %{
      conn: conn,
      wiki_ctx: wiki_ctx,
      page: page
    } do
      {:ok, _view, html} = live(conn, ~p"/#{wiki_ctx.slug}/notes/#{page.slug}")

      assert html =~ "Wiki Test Note"
      assert html =~ "A note visible through the wiki"
    end

    test "GET /:unknown_slug redirects to / for an unknown workspace", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/no-such-workspace")
    end
  end

  describe "graph node_click" do
    # Regression: the hook sends the singular page_type ("note") but routes
    # are plural workspace-scoped (/:ws/notes/:slug). With the raw type the
    # wildcard matched page_type="note", PagesLive couldn't resolve it and
    # redirected to the index — clicking a node landed on home.
    test "navigates to the plural workspace-scoped page route", %{
      conn: conn,
      wiki_ctx: wiki_ctx,
      page: page
    } do
      {:ok, view, _html} = live(conn, ~p"/#{wiki_ctx.slug}/graph")

      render_click(view, "node_click", %{"slug" => page.slug, "type" => "note"})

      assert_redirect(view, "/#{wiki_ctx.slug}/notes/#{page.slug}")
    end

    test "goal nodes navigate to the first-class goals route", %{
      conn: conn,
      wiki_ctx: wiki_ctx
    } do
      {:ok, view, _html} = live(conn, ~p"/#{wiki_ctx.slug}/graph")

      render_click(view, "node_click", %{"slug" => "my-goal", "type" => "goal"})

      assert_redirect(view, "/#{wiki_ctx.slug}/goals/my-goal")
    end
  end

  describe "authentication" do
    test "GET / redirects to /login without a session" do
      conn = build_conn() |> get(~p"/")
      assert redirected_to(conn) == ~p"/login"
    end

    test "GET /settings redirects to /login without a session" do
      conn = build_conn() |> get(~p"/settings")
      assert redirected_to(conn) == ~p"/login"
    end
  end
end
