defmodule DranWeb.API.TodoControllerTest do
  use DranWeb.ConnCase, async: false

  alias Dran.{Accounts, Knowledge, Tasks}

  setup do
    unique = System.unique_integer([:positive])

    {:ok, owner} =
      Accounts.create_user(%{
        email: "owner-#{unique}@example.com",
        name: "Owner",
        is_owner: true
      })

    {:ok, workspace} =
      Knowledge.create_workspace(%{
        name: "Todo API #{unique}",
        slug: "todo-api-#{unique}"
      })

    {:ok, key} =
      Accounts.create_api_key(%{
        name: "agent-coder-#{unique}",
        workspace_ids: [{workspace.id, "write"}],
        created_by_user_id: owner.id
      })

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("accept", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{key.token}")

    {:ok, conn: conn, workspace: workspace}
  end

  describe "PUT /api/todos/:id" do
    test "archives a task (archived: true)", %{conn: conn, workspace: workspace} do
      {:ok, task} = Tasks.create_task(%{"workspace_id" => workspace.id, "title" => "To archive"})

      conn =
        conn
        |> put("/api/todos/#{task.id}", %{archived: true})

      assert %{"data" => %{"archived" => true}} = json_response(conn, 200)
      assert Tasks.get_task(task.id).archived == true
    end

    test "unarchives a task (archived: false)", %{conn: conn, workspace: workspace} do
      {:ok, task} = Tasks.create_task(%{"workspace_id" => workspace.id, "title" => "To keep"})

      conn
      |> put("/api/todos/#{task.id}", %{archived: true})

      conn =
        conn
        |> put("/api/todos/#{task.id}", %{archived: false})

      assert %{"data" => %{"archived" => false}} = json_response(conn, 200)
      assert Tasks.get_task(task.id).archived == false
    end

    test "status is validated (invalid status returns 422)", %{conn: conn, workspace: workspace} do
      {:ok, task} =
        Tasks.create_task(%{"workspace_id" => workspace.id, "title" => "Status check"})

      conn =
        conn
        |> put("/api/todos/#{task.id}", %{status: "this_week"})

      assert %{"errors" => _} = json_response(conn, 422)
    end

    test "403 for unknown task id (no existence leak)", %{conn: conn} do
      conn =
        conn
        |> put("/api/todos/00000000-0000-0000-0000-000000000000", %{archived: true})

      assert %{"errors" => _} = json_response(conn, 403)
    end
  end
end
