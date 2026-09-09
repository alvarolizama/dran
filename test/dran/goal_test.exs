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
        slug: "test-goal"
      }

      assert {:ok, %Dran.Goals.Goal{} = goal} = Goals.create_goal(attrs)
      assert goal.title == "Test Goal"
    end
  end

  describe "get_goal_by_slug/2" do
    test "retrieves a goal by slug and workspace_id", %{context: ctx} do
      {:ok, created} =
        Goals.create_goal(%{
          workspace_id: ctx.id,
          title: "Findable Goal",
          slug: "findable-goal"
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
          slug: "goal-a"
        })

      {:ok, _} =
        Goals.create_goal(%{
          workspace_id: ctx.id,
          title: "Goal B",
          slug: "goal-b"
        })

      goals = Goals.list_goals(workspace_id: ctx.id)
      assert length(goals) == 2
    end
  end

  describe "checklist" do
    test "add_checklist_item/2 appends a pending item", %{context: ctx} do
      {:ok, goal} = Goals.create_goal(%{workspace_id: ctx.id, title: "Check", slug: "check"})

      {:ok, goal} = Goals.add_checklist_item(goal, "Primer paso")
      assert goal.checklist == [%{"text" => "Primer paso", "done" => false}]

      {:ok, goal} = Goals.add_checklist_item(goal, "  Segundo  ")
      assert Enum.map(goal.checklist, & &1["text"]) == ["Primer paso", "Segundo"]
    end

    test "add_checklist_item/2 rejects empty text", %{context: ctx} do
      {:ok, goal} = Goals.create_goal(%{workspace_id: ctx.id, title: "Check", slug: "check"})
      assert {:error, :empty_text} = Goals.add_checklist_item(goal, "   ")
    end

    test "toggle_checklist_item/2 flips done", %{context: ctx} do
      {:ok, goal} = Goals.create_goal(%{workspace_id: ctx.id, title: "Check", slug: "check"})
      {:ok, goal} = Goals.add_checklist_item(goal, "Uno")

      {:ok, goal} = Goals.toggle_checklist_item(goal, 0)
      assert hd(goal.checklist)["done"] == true
      assert Goals.checklist_progress(goal) == {1, 1}

      {:ok, goal} = Goals.toggle_checklist_item(goal, 0)
      assert hd(goal.checklist)["done"] == false
    end

    test "remove_checklist_item/2 drops the item by index", %{context: ctx} do
      {:ok, goal} = Goals.create_goal(%{workspace_id: ctx.id, title: "Check", slug: "check"})
      {:ok, goal} = Goals.add_checklist_item(goal, "Uno")
      {:ok, goal} = Goals.add_checklist_item(goal, "Dos")

      {:ok, goal} = Goals.remove_checklist_item(goal, 0)
      assert Enum.map(goal.checklist, & &1["text"]) == ["Dos"]
      assert Goals.checklist_progress(goal) == {0, 1}
    end
  end
end
