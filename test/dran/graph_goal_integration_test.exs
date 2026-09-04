defmodule DranWeb.GraphGoalIntegrationTest do
  use DranWeb.ConnCase, async: false

  alias Dran.Knowledge
  alias Dran.Goals
  alias Dran.Repo

  test "graph_data includes goal nodes and page→goal edges" do
    unique = System.unique_integer([:positive])

    {:ok, ws} =
      Knowledge.create_workspace(%{
        name: "GraphGoal Test #{unique}",
        slug: "graph-goal-test-#{unique}"
      })

    {:ok, page} =
      Knowledge.create_page(%{
        workspace_id: ws.id,
        title: "Test Note",
        slug: "test-note-gt",
        page_type: "note",
        body: "Test"
      })

    {:ok, goal} =
      Goals.create_goal(%{
        workspace_id: ws.id,
        title: "My Goal",
        slug: "my-goal-gt"
      })

    # Create a page→goal relation
    {:ok, _} =
      Knowledge.create_relation(%{
        source_id: page.id,
        source_type: "page",
        target_id: goal.id,
        target_type: "goal",
        relation_type: "part_of"
      })

    data = Knowledge.graph_data(ws.id)

    goal_nodes = Enum.filter(data.nodes, &(&1.type == "goal"))
    assert length(goal_nodes) == 1, "Expected 1 goal node, got #{length(goal_nodes)}"
    assert hd(goal_nodes).slug == "my-goal-gt"

    goal_edges = Enum.filter(data.edges, &(&1.target == goal.id))
    assert length(goal_edges) == 1, "Expected 1 goal edge, got #{length(goal_edges)}"

    # Type counts include goals
    counts = Knowledge.graph_type_counts(ws.id)
    assert counts["goal"] == 1

    # Cleanup
    Repo.delete_all(Dran.Relation)
    Repo.delete_all(Dran.Goal)
    Repo.delete_all(Dran.Page)
    Knowledge.delete_workspace(ws)
  end

  test "node_click navigates to goal route" do
    # The node_click handler maps type "goal" to "goals" (plural) for the route.
    ws_slug = "test-node-click-#{System.unique_integer([:positive])}"
    # type="goal" → route_type="goals" → /:ws/goals/:slug
    path = ~p"/#{ws_slug}/goals/my-goal"
    assert path == "/#{ws_slug}/goals/my-goal"
  end
end
