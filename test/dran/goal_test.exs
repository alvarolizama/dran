defmodule Dran.GoalTest do
  use Dran.DataCase, async: false

  alias Dran.Knowledge

  alias Dran.Goals

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

    context =
      Knowledge.get_workspace_by_slug("personal") ||
        elem(Knowledge.create_workspace(%{name: "Personal", slug: "personal"}), 1)

    {:ok, context: context}
  end

  describe "create_goal/1" do
    test "creates a goal with valid attrs", %{context: ctx} do
      attrs = %{
        workspace_id: ctx.id,
        title: "Test Goal",
        slug: "test-goal",
        metric: "completion %",
        target_value: 100.0,
        current_value: 0.0,
        unit: "%"
      }

      assert {:ok, %Dran.Goal{} = goal} = Goals.create_goal(attrs)
      assert goal.title == "Test Goal"
      assert goal.metric == "completion %"
    end
  end

  describe "get_goal_by_slug/2" do
    test "retrieves a goal by slug and workspace_id", %{context: ctx} do
      {:ok, created} =
        Goals.create_goal(%{
          workspace_id: ctx.id,
          title: "Findable Goal",
          slug: "findable-goal",
          metric: "score"
        })

      found = Goals.get_goal_by_slug("findable-goal", ctx.id)
      assert found.id == created.id
    end
  end

  describe "list_goals/1" do
    test "lists goals in a workspace", %{context: ctx} do
      {:ok, _} =
        Goals.create_goal(%{
          workspace_id: ctx.id,
          title: "Goal A",
          slug: "goal-a",
          metric: "score"
        })

      {:ok, _} =
        Goals.create_goal(%{
          workspace_id: ctx.id,
          title: "Goal B",
          slug: "goal-b",
          metric: "score"
        })

      goals = Goals.list_goals(workspace_id: ctx.id)
      assert length(goals) == 2
    end
  end
end
