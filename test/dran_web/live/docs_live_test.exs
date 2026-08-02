defmodule DranWeb.DocsLiveTest do
  use DranWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    # Disable inference scheduling so no external API calls happen during render.
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

    # init_test_session is needed because ConnCase doesn't pipe through browser.
    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user, "test_user")
      |> Plug.Conn.put_session(:context_slug, "personal")

    {:ok, conn: conn}
  end

  # ── 1. Default tab ──

  test "GET /docs renders the default tab (getting-started) with visible content", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/docs")

    # The "What is Dran?" heading should be visible on the getting-started tab.
    # The heading text is not run through gettext in the template, so it stays
    # in English regardless of locale.
    assert html =~ "What is Dran?"
  end

  # ── 2. Tab navigation ──

  test "switching to each tab reveals tab-specific content", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/docs")

    # getting-started: default tab — heading present
    assert has_element?(view, "h2", "What is Dran?")

    # concepts: planning hierarchy section (plan_slug appears in the hierarchy docs)
    view |> element(~s(button[phx-value-tab="concepts"])) |> render_click()
    html = render(view)
    assert html =~ "plan_slug"

    # guides: real-time kanban mention
    view |> element(~s(button[phx-value-tab="guides"])) |> render_click()
    html = render(view)
    assert html =~ "real-time" or html =~ "tiempo real" or html =~ "PubSub"

    # api: endpoint table — a known REST path appears
    view |> element(~s(button[phx-value-tab="api"])) |> render_click()
    html = render(view)
    assert html =~ "/api/pages"

    # mcp: MCP endpoint mention
    view |> element(~s(button[phx-value-tab="mcp"])) |> render_click()
    html = render(view)
    assert html =~ "/api/mcp"

    # auth: DRAN_API_TOKEN env var mention
    view |> element(~s(button[phx-value-tab="auth"])) |> render_click()
    html = render(view)
    assert html =~ "DRAN_API_TOKEN"
  end

  # ── 3. Concepts tab — planning hierarchy ──

  test "concepts tab contains the planning hierarchy section", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/docs")

    view |> element(~s(button[phx-value-tab="concepts"])) |> render_click()
    html = render(view)

    # plan_slug is a stable identifier used in the planning hierarchy docs.
    assert html =~ "plan_slug"
  end

  # ── 4. Guides tab — real-time kanban ──

  test "guides tab mentions the real-time kanban", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/docs")

    view |> element(~s(button[phx-value-tab="guides"])) |> render_click()
    html = render(view)

    assert html =~ "real-time" or html =~ "tiempo real" or html =~ "PubSub"
  end

  # ── 5. Table of contents per tab ──

  test "getting-started tab shows a table of contents with anchor links", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/docs")

    # getting-started is the default tab — at least 2 TOC anchor links
    assert has_element?(view, ~s(a[href="#docs-what-is-dran"]))
    assert has_element?(view, ~s(a[href="#docs-architecture"]))
  end

  test "mcp tab shows a table of contents with anchor links", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/docs")

    view |> element(~s(button[phx-value-tab="mcp"])) |> render_click()

    assert has_element?(view, ~s(a[href="#docs-mcp-endpoint"]))
    assert has_element?(view, ~s(a[href="#docs-available-tools"]))
  end

  # ── 6. handle_params with ?tab= ──

  test "handle_params with ?tab=mcp activates the mcp tab", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/docs?tab=mcp")

    # The mcp tab button should be marked active (bg-base-100 shadow-sm class).
    assert has_element?(view, ~s(button[phx-value-tab="mcp"].bg-base-100))

    # MCP content is visible.
    assert html =~ "/api/mcp"
  end

  test "handle_params with ?tab=auth activates the auth tab", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/docs?tab=auth")

    assert has_element?(view, ~s(button[phx-value-tab="auth"].bg-base-100))
    assert html =~ "DRAN_API_TOKEN"
  end
end
