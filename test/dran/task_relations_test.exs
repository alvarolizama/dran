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

  describe "list_tasks_for_goal/1" do
    test "returns tasks linked to the goal in board order, skipping archived" do
      workspace = ensure_workspace!()

      {:ok, goal} =
        Goals.create_goal(%{
          "workspace_id" => workspace.id,
          "title" => "List me",
          "slug" => "list-me"
        })

      {:ok, other_goal} =
        Goals.create_goal(%{
          "workspace_id" => workspace.id,
          "title" => "Other",
          "slug" => "other"
        })

      {:ok, t1} = Tasks.create_task(%{"workspace_id" => workspace.id, "title" => "First"})
      {:ok, t2} = Tasks.create_task(%{"workspace_id" => workspace.id, "title" => "Second"})
      {:ok, t3} = Tasks.create_task(%{"workspace_id" => workspace.id, "title" => "Third"})

      Tasks.link_to_goal(t3, goal)
      Tasks.link_to_goal(t1, goal)
      Tasks.link_to_goal(t2, other_goal)

      {:ok, _} = Tasks.update_task(t3, %{"archived" => true})

      result = Tasks.list_tasks_for_goal(goal)

      assert [%{title: "First"}] = result
      assert %{assignee_actor: nil} = hd(result)
    end
  end

  describe "set_goal/3" do
    test "links a task to a goal" do
      workspace = ensure_workspace!()

      {:ok, goal} =
        Goals.create_goal(%{
          "workspace_id" => workspace.id,
          "title" => "Set goal",
          "slug" => "set-goal"
        })

      {:ok, task} = Tasks.create_task(%{"workspace_id" => workspace.id, "title" => "T1"})

      assert {:ok, _} = Tasks.set_goal(task, goal.id)
      assert [%{id: goal_id}] = Tasks.list_linked_goals(task)
      assert goal_id == goal.id
    end

    test "is idempotent when the task already points at the goal" do
      workspace = ensure_workspace!()

      {:ok, goal} =
        Goals.create_goal(%{
          "workspace_id" => workspace.id,
          "title" => "Idem",
          "slug" => "idem"
        })

      {:ok, task} = Tasks.create_task(%{"workspace_id" => workspace.id, "title" => "T2"})

      {:ok, _} = Tasks.set_goal(task, goal.id)
      assert {:ok, _} = Tasks.set_goal(task, goal.id)
      assert Tasks.list_linked_goals(task) |> length() == 1
    end

    test "switching goals replaces the previous link and recomputes the new goal" do
      workspace = ensure_workspace!()

      {:ok, g1} =
        Goals.create_goal(%{"workspace_id" => workspace.id, "title" => "G1", "slug" => "g1"})

      {:ok, g2} =
        Goals.create_goal(%{"workspace_id" => workspace.id, "title" => "G2", "slug" => "g2"})

      {:ok, task} =
        Tasks.create_task(%{
          "workspace_id" => workspace.id,
          "title" => "Switch",
          "status" => "done"
        })

      {:ok, _} = Tasks.set_goal(task, g1.id)
      assert Goals.get_goal(g1.id).progress == 1.0

      {:ok, _} = Tasks.set_goal(task, g2.id)
      assert Tasks.list_linked_goals(task) |> Enum.map(& &1.id) == [g2.id]
      # The old goal keeps its derived progress (recompute with 0 tasks is a no-op)
      assert Goals.get_goal(g1.id).progress == 1.0
      assert Goals.get_goal(g2.id).progress == 1.0
    end

    test "empty goal_id detaches the task from its goal" do
      workspace = ensure_workspace!()

      {:ok, goal} =
        Goals.create_goal(%{
          "workspace_id" => workspace.id,
          "title" => "Empty",
          "slug" => "empty"
        })

      {:ok, task} = Tasks.create_task(%{"workspace_id" => workspace.id, "title" => "T3"})
      {:ok, _} = Tasks.set_goal(task, goal.id)

      assert {:ok, _} = Tasks.set_goal(task, "")
      assert Tasks.list_linked_goals(task) == []
    end

    test "rejects goals from another workspace" do
      workspace = ensure_workspace!()

      {:ok, other_ws} =
        Knowledge.create_workspace(%{
          name: "Other #{System.unique_integer([:positive])}",
          slug: "other-#{System.unique_integer([:positive])}"
        })

      {:ok, goal} =
        Goals.create_goal(%{"workspace_id" => other_ws.id, "title" => "Alien", "slug" => "alien"})

      {:ok, task} = Tasks.create_task(%{"workspace_id" => workspace.id, "title" => "T4"})

      assert {:error, :goal_not_found} = Tasks.set_goal(task, goal.id)
      assert Tasks.list_linked_goals(task) == []
    end

    test "rejects unknown goal ids" do
      workspace = ensure_workspace!()

      {:ok, task} = Tasks.create_task(%{"workspace_id" => workspace.id, "title" => "T5"})

      assert {:error, :goal_not_found} = Tasks.set_goal(task, Ecto.UUID.generate())
    end

    test "rejects malformed goal ids without raising" do
      workspace = ensure_workspace!()

      {:ok, task} = Tasks.create_task(%{"workspace_id" => workspace.id, "title" => "T6"})

      # Forged params: a non-UUID binary must not raise Ecto.Query.CastError
      assert {:error, :goal_not_found} = Tasks.set_goal(task, "'; DROP TABLE goals; --")
      assert {:error, :goal_not_found} = Tasks.set_goal(task, "not-a-uuid")
      assert Tasks.list_linked_goals(task) == []
    end
  end

  describe "descendant_ids/2" do
    test "returns all descendants at any depth, cycle-safe" do
      ws =
        ensure_workspace!(
          "desc-#{System.unique_integer([:positive])}",
          "Desc #{System.unique_integer([:positive])}"
        )

      {:ok, root} = Goals.create_goal(%{"workspace_id" => ws.id, "title" => "R", "slug" => "r"})

      {:ok, child} =
        Goals.create_goal(%{
          "workspace_id" => ws.id,
          "title" => "C",
          "slug" => "c",
          "parent_goal_id" => root.id
        })

      {:ok, grandchild} =
        Goals.create_goal(%{
          "workspace_id" => ws.id,
          "title" => "GC",
          "slug" => "gc",
          "parent_goal_id" => child.id
        })

      goals = Goals.list_goals(ws.id)

      assert Goals.descendant_ids(root.id, goals) |> Enum.sort() ==
               Enum.sort([child.id, grandchild.id])

      assert Goals.descendant_ids(child.id, goals) == [grandchild.id]
      assert Goals.descendant_ids(grandchild.id, goals) == []
    end
  end

  describe "actor-id attribution (F6)" do
    test "create_task resolves creator_actor_id from created_by (actor name)" do
      {:ok, agent} = Dran.Actors.create_actor(%{"name" => "attribution-agent", "kind" => "agent"})

      workspace = ensure_workspace!()

      {:ok, task} =
        Tasks.create_task(%{
          "workspace_id" => workspace.id,
          "title" => "Created by agent",
          "created_by" => "attribution-agent"
        })

      assert task.creator_actor_id == agent.id
      assert task.created_by == "attribution-agent"
    end

    test "create_task with an unknown identity carries no actor id" do
      workspace = ensure_workspace!()

      {:ok, task} =
        Tasks.create_task(%{
          "workspace_id" => workspace.id,
          "title" => "Unknown creator",
          "created_by" => "nobody-#{System.unique_integer([:positive])}"
        })

      assert task.creator_actor_id == nil
      assert task.created_by =~ "nobody-"
    end

    test "create_task with no created_by defaults to system without actor id" do
      workspace = ensure_workspace!()

      {:ok, task} = Tasks.create_task(%{"workspace_id" => workspace.id, "title" => "System"})

      assert task.created_by == "system"
      assert task.creator_actor_id == nil
    end

    test "create_task honours an explicitly passed creator_actor_id" do
      {:ok, agent} =
        Dran.Actors.create_actor(%{"name" => "explicit-actor", "kind" => "agent"})

      workspace = ensure_workspace!()

      {:ok, task} =
        Tasks.create_task(%{
          "workspace_id" => workspace.id,
          "title" => "Explicit actor",
          "created_by" => "system",
          "creator_actor_id" => agent.id
        })

      assert task.creator_actor_id == agent.id
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

      assert errors_on(changeset).target_id
             |> List.wrap()
             |> Enum.any?(&(to_string(&1) =~ "does not exist"))
    end
  end
end
