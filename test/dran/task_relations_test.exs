defmodule Dran.TaskRelationsTest do
  use Dran.DataCase, async: false

  alias Dran.{Tasks, Goals, Knowledge}

  describe "task ↔ goal links (opt-in)" do
    test "a task exists standalone without any relation" do
      workspace = ensure_workspace!()

      {:ok, task} =
        Tasks.create_task(%{"workspace_id" => workspace.id, "title" => "Standalone"})

      assert Tasks.list_linked_goals(task) == []
    end

    test "link_to_goal creates a part_of relation and derives progress" do
      workspace = ensure_workspace!()

      {:ok, goal} =
        Goals.create_goal(%{
          "workspace_id" => workspace.id,
          "title" => "Learn Elixir",
          "slug" => "learn-elixir"
        })

      {:ok, task} =
        Tasks.create_task(%{"workspace_id" => workspace.id, "title" => "Read book"})

      {:ok, _rel} = Tasks.link_to_goal(task, goal)

      # 0 done / 1 total = 0.0
      updated_goal = Goals.get_goal(goal.id)
      assert updated_goal.progress == 0.0
      assert updated_goal.meta["progress_derived"] == true
      assert Tasks.list_linked_goals(task) |> length() == 1
    end

    test "progress updates when a linked task moves to done" do
      workspace = ensure_workspace!()

      {:ok, goal} =
        Goals.create_goal(%{
          "workspace_id" => workspace.id,
          "title" => "Ship feature",
          "slug" => "ship-feature"
        })

      {:ok, t1} =
        Tasks.create_task(%{"workspace_id" => workspace.id, "title" => "Write code"})

      {:ok, t2} =
        Tasks.create_task(%{"workspace_id" => workspace.id, "title" => "Write docs"})

      Tasks.link_to_goal(t1, goal)
      Tasks.link_to_goal(t2, goal)

      # Complete one task via move (status change → recompute hook)
      {:ok, _} = Tasks.move_task(t1, "done")

      goal = Goals.get_goal(goal.id)
      assert_in_delta goal.progress, 0.5, 0.001
    end

    test "goal with no tasks keeps manual progress untouched" do
      workspace = ensure_workspace!()

      {:ok, goal} =
        Goals.create_goal(%{
          "workspace_id" => workspace.id,
          "title" => "Manual goal",
          "slug" => "manual-goal",
          "progress" => 0.7
        })

      :ok = Goals.recompute_progress(goal)

      goal = Goals.get_goal(goal.id)
      assert goal.progress == 0.7
      assert goal.meta["progress_derived"] == nil
    end

    test "unlink_from_goal removes the relation and recomputes" do
      workspace = ensure_workspace!()

      {:ok, goal} =
        Goals.create_goal(%{
          "workspace_id" => workspace.id,
          "title" => "Detach",
          "slug" => "detach"
        })

      {:ok, task} =
        Tasks.create_task(%{
          "workspace_id" => workspace.id,
          "title" => "Task",
          "status" => "done"
        })

      Tasks.link_to_goal(task, goal)
      assert Tasks.list_linked_goals(task) |> length() == 1

      {:ok, :unlinked} = Tasks.unlink_from_goal(task, goal)
      assert Tasks.list_linked_goals(task) == []
    end
  end

  describe "task ↔ page links (opt-in)" do
    test "link_to_page creates a part_of relation to a project note" do
      workspace = ensure_workspace!()

      {:ok, page} =
        Knowledge.create_page(%{
          "workspace_id" => workspace.id,
          "title" => "Dran Project",
          "slug" => "dran-project",
          "page_type" => "note",
          "meta" => %{"kind" => "project"}
        })

      {:ok, task} =
        Tasks.create_task(%{"workspace_id" => workspace.id, "title" => "Ship v1"})

      {:ok, rel} = Tasks.link_to_page(task, page)

      assert rel.source_type == "task"
      assert rel.target_type == "page"
      assert rel.relation_type == "part_of"
    end
  end

  describe "relation validation" do
    test "part_of task→goal fails when goal does not exist" do
      workspace = ensure_workspace!()

      {:ok, task} =
        Tasks.create_task(%{"workspace_id" => workspace.id, "title" => "Orphan link"})

      fake_id = Ecto.UUID.generate()

      assert {:error, changeset} =
               Knowledge.create_relation(%{
                 source_id: task.id,
                 source_type: "task",
                 target_id: fake_id,
                 target_type: "goal",
                 relation_type: "part_of"
               })

      assert ("does not exist" in errors_on(changeset).target_id)
             |> List.wrap()
             |> Enum.map(&to_string/1)
    end
  end
end
