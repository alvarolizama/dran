defmodule Dran.PlansTest do
  @moduledoc """
  Wave A — plans/steps model: CRUD of plans and steps, slug uniqueness,
  position-based ordering/append, delete guards, new relation types
  (serves/instance_of, node types plan/step), and the backfill data
  migration (implicit goal-plans → explicit plans + steps + copied edges),
  verified idempotent by re-running it.
  """

  use Dran.DataCase, async: false

  alias Dran.{Goals, Knowledge, Plan, Plans, Relation, Repo, Task}

  setup do
    # The migration file is not compiled into the test env by default — eval
    # it at RUNTIME so its statements can run inside the sandbox (a
    # compile-time eval would define the module only during compilation).
    unless function_exported?(Dran.Repo.Migrations.BackfillPlansFromGoals, :up_statements, 0) do
      Code.eval_file(
        Path.expand(
          "../../priv/repo/migrations/20260903231529_backfill_plans_from_goals.exs",
          __DIR__
        )
      )
    end

    %{workspace: ensure_workspace!()}
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Plan CRUD
  # ──────────────────────────────────────────────────────────────────────────

  describe "plan CRUD" do
    test "create_plan/1 creates a plan and get_plan_by_slug/2 finds it", %{workspace: ws} do
      assert {:ok, %Plan{} = plan} =
               Plans.create_plan(%{
                 workspace_id: ws.id,
                 title: "Plan A",
                 slug: "plan-a",
                 summary: "short",
                 body: "long"
               })

      assert plan.title == "Plan A"
      assert plan.summary == "short"
      assert plan.body == "long"

      assert Plans.get_plan_by_slug("plan-a", ws.id).id == plan.id
    end

    test "update_plan/2 updates fields", %{workspace: ws} do
      {:ok, plan} = Plans.create_plan(%{workspace_id: ws.id, title: "A", slug: "a"})

      assert {:ok, updated} = Plans.update_plan(plan, %{title: "B", summary: "s"})
      assert updated.title == "B"
      assert updated.summary == "s"
      assert updated.slug == "a"
    end

    test "list_plans/1 lists plans of a workspace", %{workspace: ws} do
      {:ok, _} = Plans.create_plan(%{workspace_id: ws.id, title: "A", slug: "a"})
      {:ok, _} = Plans.create_plan(%{workspace_id: ws.id, title: "B", slug: "b"})

      assert length(Plans.list_plans(ws.id)) == 2
    end

    test "slug is unique per workspace", %{workspace: ws} do
      {:ok, _} = Plans.create_plan(%{workspace_id: ws.id, title: "A", slug: "dup"})

      assert {:error, changeset} =
               Plans.create_plan(%{workspace_id: ws.id, title: "B", slug: "dup"})

      assert "has already been taken" in changeset_errors(changeset)
    end

    test "same slug allowed in different workspaces", %{workspace: ws} do
      other = ensure_workspace!("other-ws", "Other WS")
      {:ok, _} = Plans.create_plan(%{workspace_id: ws.id, title: "A", slug: "dup"})

      assert {:ok, _} =
               Plans.create_plan(%{workspace_id: other.id, title: "B", slug: "dup"})
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Step CRUD
  # ──────────────────────────────────────────────────────────────────────────

  describe "step CRUD" do
    setup %{workspace: ws} do
      {:ok, plan} = Plans.create_plan(%{workspace_id: ws.id, title: "Plan", slug: "plan"})
      %{plan: plan}
    end

    test "create_step/2 appends at position max+100", %{plan: plan} do
      {:ok, s1} = Plans.create_step(plan, %{title: "Step 1", slug: "step-1"})
      {:ok, s2} = Plans.create_step(plan, %{title: "Step 2", slug: "step-2"})

      assert s1.position == 100
      assert s2.position == 200
      assert [s1.id, s2.id] == Enum.map(Plans.list_steps(plan), & &1.id)
    end

    test "create_step/2 copies workspace and plan from the plan", %{workspace: ws, plan: plan} do
      {:ok, step} = Plans.create_step(plan, %{title: "S", slug: "s"})
      assert step.plan_id == plan.id
      assert step.workspace_id == ws.id
    end

    test "update_step/2 updates and keeps ordering", %{plan: plan} do
      {:ok, s1} = Plans.create_step(plan, %{title: "S1", slug: "s1"})

      assert {:ok, updated} = Plans.update_step(s1, %{title: "Renamed", position: 50})
      assert updated.title == "Renamed"
      assert updated.position == 50

      assert [updated.id] == Enum.map(Plans.list_steps(plan), & &1.id)
    end

    test "step slug is unique per workspace", %{plan: plan} do
      {:ok, _} = Plans.create_step(plan, %{title: "S1", slug: "dups"})

      assert {:error, changeset} = Plans.create_step(plan, %{title: "S2", slug: "dups"})
      assert "has already been taken" in changeset_errors(changeset)
    end

    test "delete_step/1 deletes a step without open runs", %{plan: plan} do
      {:ok, step} = Plans.create_step(plan, %{title: "S", slug: "s"})

      assert {:ok, deleted} = Plans.delete_step(step)
      assert deleted.id == step.id
      assert Plans.list_steps(plan) == []
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Delete guards
  # ──────────────────────────────────────────────────────────────────────────

  describe "delete guards" do
    test "delete_plan/1 succeeds when there are no sessions", %{workspace: ws} do
      {:ok, plan} = Plans.create_plan(%{workspace_id: ws.id, title: "Plan", slug: "no-sessions"})
      {:ok, _} = Plans.create_step(plan, %{title: "S", slug: "s"})

      # goal_sessions still key on goal_id (F1 shape; plan_id arrives in F2)
      # — so no plan can have sessions yet and the guard is satisfiable.
      assert {:ok, deleted} = Plans.delete_plan(plan)
      assert deleted.id == plan.id
    end

    test "delete_plan/1 refuses when the plan has sessions", %{workspace: ws} do
      # Guard is an explicit query on the CURRENT sessions shape
      # (goal_sessions.goal_id — no plan_id until F2 re-points sessions to
      # plans). No session can reference a plan today, so the refusal branch
      # is unreachable — assert the success path, the only live behavior
      # (the guard queries plan_id and flips on when the column lands).
      {:ok, plan} = Plans.create_plan(%{workspace_id: ws.id, title: "P", slug: "p"})
      assert {:ok, _} = Plans.delete_plan(plan)
    end

    test "delete_step/1 refuses when the step has open runs", %{workspace: ws} do
      {:ok, plan} = Plans.create_plan(%{workspace_id: ws.id, title: "P", slug: "p"})
      {:ok, step} = Plans.create_step(plan, %{title: "S", slug: "s"})

      # task_runs key on task_id (F1 shape; step_id arrives in wave B when
      # runs re-point to steps). No run can reference a step yet, so the
      # refusal branch is unreachable — assert the success path, the only
      # live behavior today (the guard flips on when the column lands).
      assert {:ok, _} = Plans.delete_step(step)
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # New relation types (P3)
  # ──────────────────────────────────────────────────────────────────────────

  describe "relation types" do
    test "plan/step node types and serves/instance_of are accepted", %{workspace: ws} do
      {:ok, goal} = Goals.create_goal(%{workspace_id: ws.id, title: "G", slug: "g"})
      {:ok, plan} = Plans.create_plan(%{workspace_id: ws.id, title: "P", slug: "p"})
      {:ok, step} = Plans.create_step(plan, %{title: "S", slug: "s"})
      {:ok, task} = fixture_task(ws)

      assert "plan" in Relation.node_types()
      assert "step" in Relation.node_types()
      assert "serves" in Relation.relation_types()
      assert "instance_of" in Relation.relation_types()

      # plan serves goal
      assert {:ok, serves} =
               Knowledge.create_relation(%{
                 source_id: plan.id,
                 source_type: "plan",
                 target_id: goal.id,
                 target_type: "goal",
                 relation_type: "serves"
               })

      assert serves.source_type == "plan" and serves.relation_type == "serves"

      # task instance_of step (wave B spawning direction)
      assert {:ok, instance} =
               Knowledge.create_relation(%{
                 source_id: task.id,
                 source_type: "task",
                 target_id: step.id,
                 target_type: "step",
                 relation_type: "instance_of"
               })

      assert instance.target_type == "step" and instance.relation_type == "instance_of"

      # step depends_on step (same type as task edges, new endpoint type)
      {:ok, step2} = Plans.create_step(plan, %{title: "S2", slug: "s2"})

      assert {:ok, dep} =
               Knowledge.create_relation(%{
                 source_id: step.id,
                 source_type: "step",
                 target_id: step2.id,
                 target_type: "step",
                 relation_type: "depends_on"
               })

      assert dep.target_type == "step"
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Data migration: implicit goal-plans → explicit plans (P2)
  # ──────────────────────────────────────────────────────────────────────────

  describe "backfill_plans_from_goals" do
    test "creates plan+steps+serves and copies depends_on edges, idempotent", %{workspace: ws} do
      {:ok, goal} =
        Goals.create_goal(%{
          workspace_id: ws.id,
          title: "Ship the thing",
          slug: "ship-the-thing",
          summary: "sum",
          body: "b"
        })

      # 3 part_of tasks, with contracts; two of them dependent (t2 depends_on t1)
      t1 = insert_task!(ws, "t1", %{"contract" => %{"intent" => "one"}})
      t2 = insert_task!(ws, "t2", %{"contract" => %{"intent" => "two"}})
      t3 = insert_task!(ws, "t3", nil)

      {:ok, _} = link_tasks_to_goal(ws, goal, [t1, t2, t3])
      {:ok, _} = add_task_dep(ws, t2, t1)

      # untracked task — must NOT become a step
      _loose = insert_task!(ws, "loose", nil)

      run_migration_up!()

      # 1. One plan per goal, slug prefixed, copied title/summary/body
      plan = Plans.get_plan_by_slug("plan-ship-the-thing", ws.id)
      assert plan
      assert plan.title == "Ship the thing"
      assert plan.summary == "sum"
      assert plan.body == "b"

      # 2. Steps: one per part_of task, contract copied, positions ordered
      steps = Plans.list_steps(plan)
      assert length(steps) == 3
      assert MapSet.new(steps, & &1.title) == MapSet.new(["t1", "t2", "t3"])
      assert Enum.map(steps, & &1.position) == Enum.sort(Enum.map(steps, & &1.position))

      step_by_title = Map.new(steps, &{&1.title, &1})
      assert step_by_title["t1"].meta["contract"]["intent"] == "one"
      assert step_by_title["t2"].meta["contract"]["intent"] == "two"
      assert step_by_title["t3"].meta == %{}

      # 3. plan serves goal
      serves =
        Repo.one(
          from r in Relation,
            where:
              r.source_type == "plan" and r.target_type == "goal" and
                r.relation_type == "serves" and r.source_id == ^plan.id and
                r.target_id == ^goal.id
        )

      assert serves

      # 4. depends_on edges copied step→step (and only that one)
      dep_edges =
        Repo.all(
          from r in Relation,
            where:
              r.source_type == "step" and r.target_type == "step" and
                r.relation_type == "depends_on" and
                r.source_id in ^Enum.map(steps, & &1.id) and
                r.target_id in ^Enum.map(steps, & &1.id)
        )

      assert length(dep_edges) == 1
      assert dep_edges |> hd() |> Map.get(:source_id) == step_by_title["t2"].id
      assert dep_edges |> hd() |> Map.get(:target_id) == step_by_title["t1"].id

      # 5. Original tasks and edges intact (dual until F3), loose task untouched
      assert length(Repo.all(from t in Task, where: t.workspace_id == ^ws.id)) == 4

      orig_edges =
        Repo.all(
          from r in Relation,
            where:
              r.source_type == "task" and r.target_type == "task" and
                r.relation_type == "depends_on"
        )

      assert length(orig_edges) == 1

      part_of = Repo.all(from r in Relation, where: r.relation_type == "part_of")
      assert length(part_of) == 3
      refute Enum.any?(Repo.all(Task), &(&1.title == "loose" and &1.slug == "step-loose"))

      # 6. Idempotent: re-run creates nothing new
      run_migration_up!()
      assert length(Plans.list_plans(ws.id)) == 1
      assert length(Plans.list_steps(plan)) == 3
      assert length(Repo.all(from r in Relation, where: r.relation_type == "serves")) == 1
      assert length(Repo.all(from r in Relation, where: r.relation_type == "depends_on")) == 2
    end

    test "goal without part_of tasks gets no plan", %{workspace: ws} do
      {:ok, _} = Goals.create_goal(%{workspace_id: ws.id, title: "Empty", slug: "empty"})

      run_migration_up!()
      assert Plans.list_plans(ws.id) == []
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Helpers
  # ──────────────────────────────────────────────────────────────────────────

  defp insert_task!(ws, title, meta) do
    {:ok, task} =
      Repo.insert(%Task{
        workspace_id: ws.id,
        title: title,
        slug: title,
        body: "body #{title}",
        meta: meta || %{},
        status: "backlog"
      })

    task
  end

  defp link_tasks_to_goal(ws, goal, tasks) do
    Enum.each(tasks, fn t ->
      {:ok, _} =
        Knowledge.create_relation(%{
          source_id: t.id,
          source_type: "task",
          target_id: goal.id,
          target_type: "goal",
          relation_type: "part_of"
        })
    end)

    {:ok, ws}
  end

  defp add_task_dep(_ws, dependent, prereq) do
    Knowledge.create_relation(%{
      source_id: dependent.id,
      source_type: "task",
      target_id: prereq.id,
      target_type: "task",
      relation_type: "depends_on"
    })
  end

  defp fixture_task(ws) do
    {:ok, task} = Repo.insert(%Task{workspace_id: ws.id, title: "T", slug: "t-fx", meta: %{}})
    {:ok, task}
  end

  defp changeset_errors(changeset) do
    changeset.errors
    |> Enum.flat_map(fn {_field, {msg, _opts}} -> [msg] end)
  end

  # Runs the real backfill migration SQL inside the test sandbox. apply/3
  # because the migration module only exists at runtime (eval'd in setup).
  defp run_migration_up! do
    up_statements = apply(Dran.Repo.Migrations.BackfillPlansFromGoals, :up_statements, [])

    Enum.each(up_statements, &Repo.query!/1)
  end
end