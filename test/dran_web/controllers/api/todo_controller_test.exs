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

  describe "PUT /api/tasks/:id" do
    test "archives a task (archived: true)", %{conn: conn, workspace: workspace} do
      {:ok, task} = Tasks.create_task(%{"workspace_id" => workspace.id, "title" => "To archive"})

      conn =
        conn
        |> put("/api/tasks/#{task.id}", %{archived: true})

      assert %{"data" => %{"archived" => true}} = json_response(conn, 200)
      assert Tasks.get_task(task.id).archived == true
    end

    test "unarchives a task (archived: false)", %{conn: conn, workspace: workspace} do
      {:ok, task} = Tasks.create_task(%{"workspace_id" => workspace.id, "title" => "To keep"})

      conn
      |> put("/api/tasks/#{task.id}", %{archived: true})

      conn =
        conn
        |> put("/api/tasks/#{task.id}", %{archived: false})

      assert %{"data" => %{"archived" => false}} = json_response(conn, 200)
      assert Tasks.get_task(task.id).archived == false
    end

    test "status is validated (invalid status returns 422)", %{conn: conn, workspace: workspace} do
      {:ok, task} =
        Tasks.create_task(%{"workspace_id" => workspace.id, "title" => "Status check"})

      conn =
        conn
        |> put("/api/tasks/#{task.id}", %{status: "this_week"})

      assert %{"errors" => _} = json_response(conn, 422)
    end

    test "403 for unknown task id (no existence leak)", %{conn: conn} do
      conn =
        conn
        |> put("/api/tasks/00000000-0000-0000-0000-000000000000", %{archived: true})

      assert %{"errors" => _} = json_response(conn, 403)
    end
  end

  describe "PUT /api/tasks/:id — workspace scoping (per-user tokens)" do
    setup %{workspace: workspace} do
      unique = System.unique_integer([:positive])

      # A second user with a per-user api_token, member of a DIFFERENT workspace.
      {:ok, outsider} =
        Accounts.create_user(%{email: "outsider-#{unique}@example.com", name: "Outsider"})

      {:ok, other_ws} =
        Knowledge.create_workspace(%{name: "Other #{unique}", slug: "other-#{unique}"})

      {:ok, member} =
        Accounts.create_user(%{email: "member-#{unique}@example.com", name: "Member"})

      # Editor role — write access in the workspace (the default role of
      # add_user_to_workspace is "viewer", which cannot write).
      {:ok, _} =
        %Dran.Accounts.UserWorkspace{}
        |> Ecto.Changeset.cast(
          %{user_id: member.id, workspace_id: workspace.id, role: "editor"},
          [:user_id, :workspace_id, :role]
        )
        |> Ecto.Changeset.validate_required([:user_id, :workspace_id])
        |> Dran.Repo.insert()

      outsider_conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("accept", "application/json")
        |> Plug.Conn.put_req_header("authorization", "Bearer #{outsider.api_token}")

      member_conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("accept", "application/json")
        |> Plug.Conn.put_req_header("authorization", "Bearer #{member.api_token}")

      %{outsider_conn: outsider_conn, member_conn: member_conn, other_ws: other_ws}
    end

    test "403 when a per-user token tries to update a task of a foreign workspace", %{
      outsider_conn: conn,
      workspace: workspace
    } do
      {:ok, task} = Tasks.create_task(%{"workspace_id" => workspace.id, "title" => "Foreign"})

      conn = put(conn, "/api/tasks/#{task.id}", %{archived: true})

      assert %{"errors" => %{"detail" => "access to workspace denied"}} = json_response(conn, 403)
      # The task was NOT touched.
      assert Tasks.get_task(task.id).archived == false
    end

    test "200 when a member of the task's workspace updates it", %{
      member_conn: conn,
      workspace: workspace
    } do
      {:ok, task} = Tasks.create_task(%{"workspace_id" => workspace.id, "title" => "Mine"})

      conn = put(conn, "/api/tasks/#{task.id}", %{archived: true})

      assert %{"data" => %{"archived" => true}} = json_response(conn, 200)
    end
  end
end
