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
end
