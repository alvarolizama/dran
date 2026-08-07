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

    context = Brain.get_context_by_slug("personal")

    {:ok, note} =
      Brain.create_page(%{
        context_id: context.id,
        title: "Graph JSON Note",
        page_type: "note"
      })

    {:ok, todo} =
      Brain.create_page(%{
        context_id: context.id,
        title: "Graph JSON Todo",
        page_type: "todo"
      })

    {:ok, _} =
      Brain.create_relation_by_slugs(note.slug, todo.slug, "related", context.id)

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user, "test_user")
      |> Plug.Conn.put_session(:context_slug, "personal")

    {:ok, conn: conn, note: note, todo: todo}
  end

  test "GET /api/graph-json returns nodes and edges excluding hidden types", %{
    conn: conn,
    note: note
  } do
    conn = get(conn, ~p"/api/graph-json")

    assert %{
             "nodes" => nodes,
             "edges" => edges,
             "total_nodes" => total_nodes,
             "total_edges" => total_edges,
             "type_counts" => type_counts,
             "capped" => capped
           } = json_response(conn, 200)

    # Note is present, todo is excluded (hidden type)
    assert Enum.any?(nodes, &(&1["slug"] == note.slug))
    refute Enum.any?(nodes, &(&1["type"] == "todo"))
    refute Enum.any?(nodes, &(&1["type"] == "plan"))

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

  test "GET /api/graph-json respects max_nodes param", %{conn: conn} do
    conn = get(conn, ~p"/api/graph-json?max_nodes=1")

    assert %{"nodes" => nodes, "total_nodes" => total} = json_response(conn, 200)

    # Capped to 1 node but total is real
    assert length(nodes) <= 1
    assert total >= 1
  end

  test "GET /api/graph-json requires authentication" do
    # Create a user so auth plug redirects to /login instead of /setup
    {:ok, _user} =
      Dran.Accounts.create_user_with_password(%{
        email: "graph-json-test@example.com",
        password: "supersecret123"
      })

    conn = build_conn()
    conn = get(conn, ~p"/api/graph-json")

    assert redirected_to(conn, 302) == "/login"
  end
end
