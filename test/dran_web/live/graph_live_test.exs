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

    context = Brain.get_context_by_slug("personal")

    # Pages of every relevant type so the global graph has a mixed dataset
    # (knowledge layer + operational layer) to filter by.
    {:ok, note} =
      Brain.create_page(%{
        context_id: context.id,
        title: "Alpha Note",
        body: "First note for graph test",
        page_type: "note"
      })

    {:ok, _concept} =
      Brain.create_page(%{
        context_id: context.id,
        title: "Beta Concept",
        body: "Second page for graph test",
        page_type: "concept"
      })

    {:ok, goal} =
      Brain.create_page(%{context_id: context.id, title: "Test Goal", page_type: "goal"})

    {:ok, plan} =
      Brain.create_page(%{context_id: context.id, title: "Test Plan", page_type: "plan"})

    {:ok, todo} =
      Brain.create_page(%{context_id: context.id, title: "Test Todo", page_type: "todo"})

    {:ok, project} =
      Brain.create_page(%{context_id: context.id, title: "Test Project", page_type: "project"})

    # Relations: operational layer hangs off strategic hubs, knowledge
    # touches goals — the shape the filter must preserve.
    {:ok, _} =
      Brain.create_relation_by_slugs(todo.slug, goal.slug, "part_of", context.id)

    {:ok, _} =
      Brain.create_relation_by_slugs(note.slug, goal.slug, "related", context.id)

    {:ok, _} =
      Brain.create_relation_by_slugs(plan.slug, project.slug, "part_of", context.id)

    {:ok, _} =
      Brain.create_relation_by_slugs(note.slug, todo.slug, "related", context.id)

    # Log in — init_test_session is needed because ConnCase doesn't pipe through browser
    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user, "test_user")
      |> Plug.Conn.put_session(:context_slug, "personal")

    {:ok, conn: conn, todo: todo, goal: goal}
  end

  # The 3D hook receives the graph as JSON inside the #graph-3d element's
  # data-graph attribute. Parse it back so tests assert on the real payload.
  defp graph_from_html(html) do
    [_, encoded] = Regex.run(~r/data-graph="([^"]*)"/, html)

    encoded
    |> String.replace("&quot;", "\"")
    |> String.replace("&amp;", "&")
    |> String.replace("&#39;", "'")
    |> Jason.decode!()
  end

  defp graph_types(graph), do: graph["nodes"] |> Enum.map(& &1["type"]) |> Enum.uniq()

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

  describe "global graph type filter" do
    test "index excludes the operational layer (todo, plan) entirely", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/graph")

      graph = graph_from_view(view)
      types = graph_types(graph)

      refute "todo" in types, "todos should be excluded from the global graph"
      refute "plan" in types, "plans should be excluded from the global graph"

      # Strategic hubs and knowledge stay visible
      assert "goal" in types
      assert "project" in types
      assert "note" in types
      assert "concept" in types

      # No edge points at a hidden node
      assert_edges_connect_visible_nodes(graph)
    end

    test "sidebar omits plan and todo, lists the rest as toggles", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/graph")

      html = render(view)

      # No toggle exists to bring the operational layer back
      refute html =~ ~s(phx-value-type="todo")
      refute html =~ ~s(phx-value-type="plan")

      # The remaining types are toggleable
      assert html =~ ~s(phx-value-type="goal")
      assert html =~ ~s(phx-value-type="project")
      assert html =~ ~s(phx-value-type="note")
      assert html =~ ~s(phx-value-type="concept")
    end

    test "toggle_type hides a visible type and drops its edges", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/graph")

      assert "note" in graph_types(graph_from_view(view))

      view |> render_hook("toggle_type", %{"type" => "note"})

      graph = graph_from_view(view)

      refute "note" in graph_types(graph)
      assert_edges_connect_visible_nodes(graph)
    end

    test "toggling a visible type off and on restores the original state", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/graph")

      view |> render_hook("toggle_type", %{"type" => "goal"})
      refute "goal" in graph_types(graph_from_view(view))

      view |> render_hook("toggle_type", %{"type" => "goal"})
      assert "goal" in graph_types(graph_from_view(view))
    end
  end

  describe "per-page subgraph" do
    test "show view includes the operational layer, unfiltered", %{conn: conn, todo: todo} do
      {:ok, view, _html} = live(conn, ~p"/graph/#{todo.slug}")

      graph = graph_from_view(view)
      types = graph_types(graph)

      # The center itself is a todo and its part_of goal neighbor shows up —
      # the subgraph must NOT apply the global filter.
      assert "todo" in types
      assert "goal" in types
    end
  end
end
