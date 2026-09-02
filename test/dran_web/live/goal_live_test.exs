defmodule DranWeb.GoalLiveTest do
  use DranWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Dran.{Goals, Knowledge, Tasks}

  defp t(msgid), do: Gettext.gettext(DranWeb.Gettext, msgid)

  setup do
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

    {:ok, ws} = Knowledge.create_workspace(%{name: "Goal Test", slug: "goal-test"})

    {:ok, goal} =
      Goals.create_goal(%{
        "workspace_id" => ws.id,
        "title" => "Learn Elixir",
        "slug" => "learn-elixir"
      })

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user, "test_user")
      |> Plug.Conn.put_session(:workspace_slug, ws.slug)
      |> Plug.Conn.put_session(:is_owner, true)

    {:ok, conn: conn, ws: ws, goal: goal}
  end

  describe "show" do
    test "renders the goal with no linked tasks", %{conn: conn, ws: ws, goal: goal} do
      {:ok, _view, html} = live(conn, ~p"/#{ws.slug}/goals/#{goal.slug}")

      assert html =~ "Learn Elixir"
      refute html =~ t("Linked tasks")
    end

    test "lists tasks linked via part_of", %{conn: conn, ws: ws, goal: goal} do
      {:ok, task} =
        Tasks.create_task(%{
          "workspace_id" => ws.id,
          "title" => "Read the book",
          "status" => "in_progress"
        })

      {:ok, _} = Tasks.link_to_goal(task, goal)

      {:ok, _view, html} = live(conn, ~p"/#{ws.slug}/goals/#{goal.slug}")

      assert html =~ t("Linked tasks")
      assert html =~ "Read the book"
    end

    test "done tasks render struck through", %{conn: conn, ws: ws, goal: goal} do
      {:ok, task} =
        Tasks.create_task(%{"workspace_id" => ws.id, "title" => "Finished", "status" => "done"})

      {:ok, _} = Tasks.link_to_goal(task, goal)

      {:ok, _view, html} = live(conn, ~p"/#{ws.slug}/goals/#{goal.slug}")

      assert html =~ "Finished"
      assert html =~ "line-through"
    end

    test "shows a link to the task board", %{conn: conn, ws: ws, goal: goal} do
      {:ok, _view, html} = live(conn, ~p"/#{ws.slug}/goals/#{goal.slug}")

      assert html =~ ~s(href="/#{ws.slug}/tasks")
    end

    test "refreshes linked tasks on a task_changed broadcast", %{conn: conn, ws: ws, goal: goal} do
      {:ok, task} = Tasks.create_task(%{"workspace_id" => ws.id, "title" => "Live added"})

      {:ok, view, _html} = live(conn, ~p"/#{ws.slug}/goals/#{goal.slug}")
      refute render(view) =~ "Live added"

      # link_to_goal triggers the real broadcast_task_change on the
      # workspace topic — the exact production path, no manual broadcast.
      {:ok, _} = Tasks.link_to_goal(task, goal)

      assert render(view) =~ "Live added"
    end
  end
end
