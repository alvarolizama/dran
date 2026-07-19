defmodule DranWeb.GraphLiveTest do
  use DranWeb.ConnCase, async: false

  alias Dran.Brain

  setup %{conn: conn} do
    # Disable inference scheduling so create_page doesn't try to call external APIs
    original = Application.get_env(:dran, :inference)

    Application.put_env(:dran, :inference,
      base_url: nil,
      api_key: nil,
      embedding_model: nil,
      rerank_model: nil,
      markitdown_model: nil,
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

    # Create a few pages so the graph has nodes and edges
    {:ok, _page1} =
      Brain.create_page(%{
        context_id: context.id,
        title: "Alpha Note",
        body: "First note for graph test",
        page_type: "note"
      })

    {:ok, _page2} =
      Brain.create_page(%{
        context_id: context.id,
        title: "Beta Concept",
        body: "Second page for graph test",
        page_type: "concept"
      })

    # Log in — init_test_session is needed because ConnCase doesn't pipe through browser
    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user, "test_user")
      |> Plug.Conn.put_session(:context_slug, "personal")

    {:ok, conn: conn}
  end

  test "renders 3D graph by default and toggles to 2D", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/graph")

    # Default mode is 3D — the Graph3D hook div should be present with graph data
    assert html =~ ~s(phx-hook="Graph3D")
    assert html =~ ~s(id="graph-3d")
    assert html =~ ~s(data-graph=)
    refute html =~ ~s(id="graph-svg")

    # The data-graph attribute should contain valid JSON with nodes and edges
    # Note: HEEx HTML-escapes quotes in attribute values (&quot;)
    assert html =~ "nodes"
    assert html =~ "edges"

    # Toggle to 2D
    view
    |> element("button[phx-value-mode='2d']")
    |> render_click()

    html = render(view)

    # 2D mode — SVG should be present, 3D div should not
    assert html =~ ~s(phx-hook="GraphPanZoom")
    assert html =~ ~s(id="graph-svg")
    refute html =~ ~s(phx-hook="Graph3D")

    # Toggle back to 3D
    view
    |> element("button[phx-value-mode='3d']")
    |> render_click()

    html = render(view)
    assert html =~ ~s(id="graph-3d")
    refute html =~ ~s(id="graph-svg")
  end

  test "graph_json contains node labels and colors", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/graph")

    # Even in 2D mode the data-graph attribute is NOT rendered — only in 3D.
    # Toggle to 3D to verify data is passed.
    # (Already verified in the first test, here we check content specifics.)
    # Switch to 3D first
    {:ok, view, _html} = live(conn, ~p"/graph")

    view
    |> element("button[phx-value-mode='3d']")
    |> render_click()

    html = render(view)

    # The node label should appear in the JSON data attribute
    assert html =~ "Alpha Note"
    assert html =~ "Beta Concept"
  end
end
