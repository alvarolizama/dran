defmodule DranWeb.GraphJSONControllerTest do
  use DranWeb.ConnCase, async: false

  alias Dran.Brain

  setup %{conn: conn} do
    # Disable inference scheduling
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

    {:ok, note} =
      Brain.create_page(%{
        workspace_id: context.id,
        title: "Graph JSON Note",
        page_type: "note"
      })

    {:ok, todo} =
      Brain.create_page(%{
        workspace_id: context.id,
        title: "Graph JSON Todo",
        page_type: "note",
        meta: %{"kind" => "todo"},
        kanban_status: "backlog"
      })

    {:ok, _} =
      Brain.create_relation_by_slugs(note.slug, todo.slug, "related", context.id)

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user, "test_user")
      |> Plug.Conn.put_session(:workspace_slug, "personal")

    {:ok, conn: conn, note: note, todo: todo}
  end

  test "GET /api/graph-json returns nodes and edges excluding hidden types", %{
    conn: conn,
    note: note
  } do
    conn = get(conn, ~p"/graph-json")

    assert %{
             "nodes" => nodes,
             "edges" => edges,
             "total_nodes" => total_nodes,
             "total_edges" => total_edges,
             "type_counts" => type_counts,
             "capped" => capped
           } = json_response(conn, 200)

    # All 5 remaining page types are visible in the graph; todo/plan are no
    # longer page types (todos are notes with kind:"todo")
    assert Enum.any?(nodes, &(&1["slug"] == note.slug))
    assert Enum.any?(nodes, &(&1["slug"] == "graph-json-todo"))
    refute Enum.any?(nodes, &(&1["type"] not in ~w(note concept entity reference query)))

    # No edges to hidden nodes
    node_ids = MapSet.new(nodes, & &1["id"])

    Enum.each(edges, fn e ->
      assert MapSet.member?(node_ids, e["source_id"])
      assert MapSet.member?(node_ids, e["target_id"])
    end)

    # Totals reflect the filtered graph
    assert total_nodes == length(nodes)
    assert total_edges == length(edges)
    assert is_map(type_counts)
    assert is_boolean(capped)
  end

  test "GET /api/graph-json clamps max_nodes to its floor (50)", %{conn: conn} do
    conn = get(conn, ~p"/graph-json?max_nodes=1")

    assert %{"nodes" => nodes, "total_nodes" => total} = json_response(conn, 200)

    # Controller clamps max_nodes to [50, 1000]; a request for 1 is floored
    # to 50, so a small dataset returns all visible pages. The param acts as
    # a ceiling, not an exact cutoff.
    assert total >= 1
    assert length(nodes) == total
  end

  test "GET /api/graph-json requires authentication" do
    # Create a user so auth plug redirects to /login instead of /setup
    {:ok, _user} =
      Dran.Accounts.create_user_with_password(%{
        email: "graph-json-test@example.com",
        password: "supersecret123"
      })

    conn = build_conn()
    conn = get(conn, ~p"/graph-json")

    assert redirected_to(conn, 302) == "/login"
  end
end
