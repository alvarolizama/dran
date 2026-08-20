defmodule DranWeb.GraphLiveTest do
  use DranWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Dran.Brain

  setup %{conn: conn} do
    # Disable inference scheduling so create_page doesn't try to call external APIs
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

    context = Brain.get_workspace_by_slug("personal")

    # Pages of every relevant type so the global graph has a mixed dataset
    # (knowledge layer + operational layer) to filter by.
    {:ok, note} =
      Brain.create_page(%{
        workspace_id: context.id,
        title: "Alpha Note",
        body: "First note for graph test",
        page_type: "note"
      })

    {:ok, _concept} =
      Brain.create_page(%{
        workspace_id: context.id,
        title: "Beta Concept",
        body: "Second page for graph test",
        page_type: "concept"
      })

    {:ok, goal} =
      Brain.create_goal(%{workspace_id: context.id, title: "Test Goal", slug: "test-goal"})

    {:ok, plan} =
      Brain.create_page(%{
        workspace_id: context.id,
        title: "Test Plan",
        slug: "test-plan",
        page_type: "note",
        meta: %{"kind" => "plan"}
      })

    {:ok, todo} =
      Brain.create_page(%{
        workspace_id: context.id,
        title: "Test Todo",
        slug: "test-todo",
        page_type: "note",
        meta: %{"kind" => "todo"},
        kanban_status: "backlog"
      })

    {:ok, _project} =
      Brain.create_page(%{
        workspace_id: context.id,
        title: "Test Project",
        slug: "test-project",
        page_type: "note",
        meta: %{"kind" => "project"}
      })

    # Relations: notes connect to each other — the subgraph shape the filter
    # must preserve. Goals/projects live in their own tables now, so they are
    # not graph nodes (relations are page-to-page only).
    {:ok, _} =
      Brain.create_relation_by_slugs(todo.slug, plan.slug, "related", context.id)

    {:ok, _} =
      Brain.create_relation_by_slugs(note.slug, todo.slug, "related", context.id)

    # Log in — init_test_session is needed because ConnCase doesn't pipe through browser
    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user, "test_user")
      |> Plug.Conn.put_session(:workspace_slug, "personal")

    {:ok, conn: conn, todo: todo, goal: goal}
  end

  # Show mode: the subgraph is serialized into the #graph-3d element's
  # data-graph attribute. Parse it back so tests assert on the real payload.
  defp graph_from_html(html) do
    [_, encoded] = Regex.run(~r/data-graph="([^"]*)"/, html)

    encoded
    |> String.replace("&quot;", "\"")
    |> String.replace("&amp;", "&")
    |> String.replace("&#39;", "'")
    |> Jason.decode!()
  end

  # Wave 2: index mode keeps the graph data in the hook client-side. The
  # progressive fetch now pushes only counters back to the LV, so we simulate
  # that lightweight payload (never nodes/edges).
  defp push_graph_loaded(view, context) do
    %{total_nodes: total_nodes, total_edges: total_edges} =
      Brain.graph_data(context.id, exclude_types: ~w(todo plan), max_nodes: 400)

    type_counts = Brain.graph_type_counts(context.id, ~w(todo plan))

    render_hook(view, "graph_loaded", %{
      "total_nodes" => total_nodes,
      "total_edges" => total_edges,
      "type_counts" => type_counts
    })
  end

  defp graph_from_view(view), do: view |> render() |> graph_from_html()

  defp assert_edges_connect_visible_nodes(graph) do
    ids = MapSet.new(graph["nodes"], & &1["id"])

    Enum.each(graph["edges"], fn e ->
      assert MapSet.member?(ids, e["source_id"]),
             "edge source #{e["source_id"]} is not a visible node"

      assert MapSet.member?(ids, e["target_id"]),
             "edge target #{e["target_id"]} is not a visible node"
    end)
  end

  describe "global graph index" do
    test "mounts the hook div even when the graph starts empty (no empty-state)", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/graph")

      # Wave 1: the hook div must exist on the initial render (nodes are empty
      # in progressive mode) or the client-side fetch never starts.
      assert html =~ ~s(phx-hook="Graph3D")
      assert html =~ ~s(id="graph-3d")
      refute html =~ "No graph data"

      # The initial visible_types are passed to the hook via data-visible-types.
      assert html =~ ~s(data-visible-types=)

      # data-graph is empty — the hook must fetch /api/graph-json over HTTP.
      graph = graph_from_view(view)
      assert graph["nodes"] == []
      assert graph["edges"] == []

      # The payload is lightweight: no nodes/edges pushed over the socket.
      assert render(view) =~ ~s(data-visible-types=)
    end

    test "graph_loaded pushes only counters, not nodes/edges", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/graph")

      context = Brain.get_workspace_by_slug("personal")
      push_graph_loaded(view, context)

      # After the fetch the sidebar totals reflect the counters, and the
      # rendered data-graph remains an empty payload (the dataset lives in the
      # hook, not in the socket).
      html = render(view)
      assert html =~ ~s(data-visible-types=)
      graph = graph_from_view(view)
      assert graph["nodes"] == []
      assert graph["edges"] == []
    end

    test "toggle_type pushes set_visible_types to the hook (client-side filter)", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/graph")

      # Toggling a type off must tell the hook to hide it client-side — the
      # LiveView no longer filters nodes over the socket.
      view |> render_hook("toggle_type", %{"type" => "note"})

      assert_push_event(view, "set_visible_types", %{types: types})
      refute "note" in types
      assert "concept" in types
    end

    test "toggling a visible type off and on restores it in the pushed set", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/graph")

      view |> render_hook("toggle_type", %{"type" => "concept"})
      assert_push_event(view, "set_visible_types", %{types: types})
      refute "concept" in types

      view |> render_hook("toggle_type", %{"type" => "concept"})
      assert_push_event(view, "set_visible_types", %{types: types})
      assert "concept" in types
    end

    test "sidebar lists the remaining types as toggles", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/graph")

      html = render(view)

      # The removed types have no toggles
      refute html =~ ~s(phx-value-type="todo")
      refute html =~ ~s(phx-value-type="plan")
      refute html =~ ~s(phx-value-type="goal")
      refute html =~ ~s(phx-value-type="project")

      # The remaining types are toggleable
      assert html =~ ~s(phx-value-type="note")
      assert html =~ ~s(phx-value-type="concept")
    end
  end

  describe "per-page subgraph" do
    test "show view includes the full subgraph, unfiltered", %{conn: conn, todo: todo} do
      {:ok, view, _html} = live(conn, ~p"/graph/#{todo.slug}")

      graph = graph_from_view(view)
      types = graph["nodes"] |> Enum.map(& &1["type"]) |> Enum.uniq()

      # The center is a note (kind:todo) and its related neighbors are notes —
      # the subgraph must NOT apply the global filter and includes them all.
      assert "note" in types
      assert length(graph["nodes"]) >= 2

      # Wave 3: show-mode payload carries no dead layout coordinates.
      assert Enum.all?(graph["nodes"], &(not Map.has_key?(&1, "x")))
      assert Enum.all?(graph["nodes"], &(not Map.has_key?(&1, "y")))
      assert Enum.all?(graph["nodes"], &(not Map.has_key?(&1, "radius")))
      assert Enum.all?(graph["edges"], &(not Map.has_key?(&1, "x1")))
      assert Enum.all?(graph["edges"], &(not Map.has_key?(&1, "y2")))
    end

    test "toggle_type off and on in show mode is non-destructive", %{conn: conn, todo: todo} do
      {:ok, view, _html} = live(conn, ~p"/graph/#{todo.slug}")

      graph = graph_from_view(view)
      initial_count = length(graph["nodes"])

      # Toggle "note" off (the center and its neighbors are all notes)
      view |> render_hook("toggle_type", %{"type" => "note"})
      graph_hidden = graph_from_view(view)
      refute graph_hidden["nodes"] |> Enum.any?(&(&1["type"] == "note"))

      # Toggle "note" back on — all original nodes must return
      view |> render_hook("toggle_type", %{"type" => "note"})
      graph_restored = graph_from_view(view)

      assert length(graph_restored["nodes"]) == initial_count,
             "toggle off-on must restore all original nodes (non-destructive)"
    end
  end
end
