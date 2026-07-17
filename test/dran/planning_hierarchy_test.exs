defmodule Dran.PlanningHierarchyTest do
  use Dran.DataCase, async: false

  alias Dran.Brain

  # Same setup as brain_test: disable inference so create_page doesn't call
  # external embedding/rerank APIs, and ensure a "personal" context exists.
  setup do
    original = Application.get_env(:dran, :inference)

    Application.put_env(:dran, :inference,
      base_url: nil,
      api_key: nil,
      embedding_model: nil,
      rerank_model: nil,
      markitdown_model: nil,
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
      Brain.get_context_by_slug("personal") ||
        elem(Brain.create_context(%{name: "Personal", slug: "personal"}), 1)

    {:ok, context: context}
  end

  # Helpers ──────────────────────────────────────────────────────────────────

  defp create_goal(ctx, slug) do
    {:ok, goal} =
      Brain.create_page(%{
        context_id: ctx.id,
        title: slug,
        slug: slug,
        page_type: "goal",
        body: "",
        meta: %{"health" => "green"}
      })

    goal
  end

  defp create_plan(ctx, slug, goal_slug) do
    meta = if goal_slug, do: %{"goal_slug" => goal_slug, "status" => "draft", "horizon" => "weekly"}, else: %{"status" => "draft", "horizon" => "weekly"}

    {:ok, plan} =
      Brain.create_page(%{
        context_id: ctx.id,
        title: slug,
        slug: slug,
        page_type: "plan",
        body: "",
        meta: meta
      })

    plan
  end

  defp create_todo(ctx, slug, opts) do
    opts = opts || []
    meta = %{"kanban_status" => "backlog", "priority" => "medium"}

    meta =
      meta
      |> maybe_put("plan_slug", Keyword.get(opts, :plan_slug))
      |> maybe_put("goal_slug", Keyword.get(opts, :goal_slug))

    {:ok, todo} =
      Brain.create_page(%{
        context_id: ctx.id,
        title: slug,
        slug: slug,
        page_type: "todo",
        body: "",
        meta: meta
      })

    todo
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Collect the slugs of outbound part_of targets for a page.
  defp part_of_targets(page) do
    page.id
    |> Brain.list_relations_for_page()
    |> Map.get(:outbound, [])
    |> Enum.filter(&(&1.relation_type == "part_of"))
    |> Enum.map(& &1.target.slug)
  end

  # ── list_pages goal_slug filter (via join) ────────────────────────────────

  describe "list_pages goal_slug filter" do
    test "todo with plan_slug appears when filtering by the plan's goal", %{context: ctx} do
      goal = create_goal(ctx, "ship-v1")
      create_plan(ctx, "q3-plan", goal.slug)
      create_todo(ctx, "write-tests", plan_slug: "q3-plan")

      # The todo has no goal_slug of its own — it should still be found via
      # the join through its plan's goal_slug.
      todos =
        Brain.list_pages(context_id: ctx.id, type: "todo", goal_slug: goal.slug)

      slugs = Enum.map(todos, & &1.slug)
      assert "write-tests" in slugs
    end

    test "todo hanging directly off a goal (no plan) is found via goal_slug", %{context: ctx} do
      goal = create_goal(ctx, "learn-rust")
      create_todo(ctx, "read-book", goal_slug: goal.slug)

      todos =
        Brain.list_pages(context_id: ctx.id, type: "todo", goal_slug: goal.slug)

      slugs = Enum.map(todos, & &1.slug)
      assert "read-book" in slugs
    end

    test "goal_slug=none returns only plans without a goal", %{context: ctx} do
      goal = create_goal(ctx, "g1")
      create_plan(ctx, "plan-with-goal", goal.slug)
      create_plan(ctx, "plan-orphan", nil)

      plans =
        Brain.list_pages(context_id: ctx.id, type: "plan", goal_slug: "none")

      slugs = Enum.map(plans, & &1.slug)
      assert "plan-orphan" in slugs
      refute "plan-with-goal" in slugs
    end

    test "plan with goal_slug appears in goal_slug filter", %{context: ctx} do
      goal = create_goal(ctx, "g-plan")
      create_plan(ctx, "p1", goal.slug)

      plans =
        Brain.list_pages(context_id: ctx.id, type: "plan", goal_slug: goal.slug)

      slugs = Enum.map(plans, & &1.slug)
      assert "p1" in slugs
    end
  end

  # ── list_pages plan_slug filter ────────────────────────────────────────────

  describe "list_pages plan_slug filter" do
    test "exact match returns todos pointing at that plan", %{context: ctx} do
      create_plan(ctx, "p2", nil)
      create_todo(ctx, "t-in-plan", plan_slug: "p2")
      create_todo(ctx, "t-orphan", nil)

      todos =
        Brain.list_pages(context_id: ctx.id, type: "todo", plan_slug: "p2")

      slugs = Enum.map(todos, & &1.slug)
      assert "t-in-plan" in slugs
      refute "t-orphan" in slugs
    end

    test "plan_slug=none returns todos without a plan", %{context: ctx} do
      create_plan(ctx, "p3", nil)
      create_todo(ctx, "t-with-plan", plan_slug: "p3")
      create_todo(ctx, "t-no-plan", nil)

      todos =
        Brain.list_pages(context_id: ctx.id, type: "todo", plan_slug: "none")

      slugs = Enum.map(todos, & &1.slug)
      assert "t-no-plan" in slugs
      refute "t-with-plan" in slugs
    end

    test "plan_slug=none AND goal_slug=none returns only orphan todos", %{context: ctx} do
      goal = create_goal(ctx, "g-orphan")
      create_plan(ctx, "p-orphan", nil)
      create_todo(ctx, "t-orphan", nil)
      create_todo(ctx, "t-with-plan", plan_slug: "p-orphan")
      create_todo(ctx, "t-with-goal", goal_slug: goal.slug)

      todos =
        Brain.list_pages(
          context_id: ctx.id,
          type: "todo",
          plan_slug: "none",
          goal_slug: "none"
        )

      slugs = Enum.map(todos, & &1.slug)
      assert "t-orphan" in slugs
      refute "t-with-plan" in slugs
      refute "t-with-goal" in slugs
    end
  end

  # ── part_of materialization ────────────────────────────────────────────────

  describe "sync_planning_relations part_of materialization" do
    test "todo with plan_slug creates part_of todo→plan", %{context: ctx} do
      create_plan(ctx, "p-mat", nil)
      todo = create_todo(ctx, "t-mat", plan_slug: "p-mat")

      assert "p-mat" in part_of_targets(todo)
    end

    test "plan with goal_slug creates part_of plan→goal", %{context: ctx} do
      create_goal(ctx, "g-mat")
      plan = create_plan(ctx, "p-goal", "g-mat")

      assert "g-mat" in part_of_targets(plan)
    end

    test "todo directly on goal (no plan) creates part_of todo→goal", %{context: ctx} do
      create_goal(ctx, "g-direct")
      todo = create_todo(ctx, "t-direct", goal_slug: "g-direct")

      assert "g-direct" in part_of_targets(todo)
    end

    test "changing a plan's goal removes the old part_of and adds the new one", %{
      context: ctx
    } do
      old_goal = create_goal(ctx, "g-old")
      new_goal = create_goal(ctx, "g-new")
      plan = create_plan(ctx, "p-switch", old_goal.slug)

      # Sanity: old part_of exists.
      assert old_goal.slug in part_of_targets(plan)

      # Switch the plan to a new goal (meta is replaced entirely on update).
      {:ok, updated} =
        Brain.update_page(plan, %{
          meta: %{"goal_slug" => new_goal.slug, "status" => "draft", "horizon" => "weekly"}
        })

      targets = part_of_targets(updated)
      assert new_goal.slug in targets
      refute old_goal.slug in targets
    end

    test "removing a plan's goal drops the part_of", %{context: ctx} do
      goal = create_goal(ctx, "g-drop")
      plan = create_plan(ctx, "p-drop", goal.slug)
      assert goal.slug in part_of_targets(plan)

      {:ok, updated} =
        Brain.update_page(plan, %{
          meta: %{"status" => "draft", "horizon" => "weekly"}
        })

      refute goal.slug in part_of_targets(updated)
    end

    test "changing a todo's plan moves the part_of to the new plan", %{context: ctx} do
      create_plan(ctx, "p-a", nil)
      create_plan(ctx, "p-b", nil)
      todo = create_todo(ctx, "t-move", plan_slug: "p-a")
      assert "p-a" in part_of_targets(todo)

      {:ok, updated} =
        Brain.update_page(todo, %{
          meta: %{
            "kanban_status" => "backlog",
            "priority" => "medium",
            "plan_slug" => "p-b"
          }
        })

      targets = part_of_targets(updated)
      assert "p-b" in targets
      refute "p-a" in targets
    end

    test "adding a plan_slug to a todo that hung off a goal drops the todo→goal part_of",
         %{context: ctx} do
      create_goal(ctx, "g-trans")
      create_plan(ctx, "p-trans", nil)
      todo = create_todo(ctx, "t-trans", goal_slug: "g-trans")
      assert "g-trans" in part_of_targets(todo)

      {:ok, updated} =
        Brain.update_page(todo, %{
          meta: %{
            "kanban_status" => "backlog",
            "priority" => "medium",
            "plan_slug" => "p-trans"
          }
        })

      targets = part_of_targets(updated)
      assert "p-trans" in targets
      refute "g-trans" in targets
    end

    test "a plan_slug pointing to a non-existent plan does not fail", %{context: ctx} do
      todo = create_todo(ctx, "t-broken", plan_slug: "no-such-plan")

      # No part_of created (target doesn't exist), but no crash either.
      assert part_of_targets(todo) == []
    end

    test "manually-created part_of to an unrelated target is preserved", %{context: ctx} do
      # A goal the todo is NOT linked to via meta.
      create_goal(ctx, "g-manual")
      create_plan(ctx, "p-manual", nil)
      todo = create_todo(ctx, "t-manual", plan_slug: "p-manual")

      # Create a manual part_of todo→g-manual (unrelated to the meta plan_slug).
      {:ok, _} =
        Brain.create_relation(%{
          source_id: todo.id,
          target_id: Brain.get_page_by_slug("g-manual", todo.context_id).id,
          relation_type: "part_of"
        })

      targets = part_of_targets(todo)
      # Both the meta-driven (p-manual) and the manual (g-manual) survive.
      assert "p-manual" in targets
      assert "g-manual" in targets
    end
  end

  # ── lint reports broken planning refs ──────────────────────────────────────

  describe "lint planning refs" do
    test "broken_plan_refs flags todos with non-existent plan_slug", %{context: ctx} do
      create_plan(ctx, "real-plan", nil)
      create_todo(ctx, "t-ok", plan_slug: "real-plan")
      create_todo(ctx, "t-broken", plan_slug: "ghost-plan")

      report = Brain.lint(ctx.id)

      broken_slugs = Enum.map(report.broken_plan_refs, & &1.slug)
      assert "t-broken" in broken_slugs
      refute "t-ok" in broken_slugs
    end

    test "broken_goal_refs flags plans/todos with non-existent goal_slug", %{context: ctx} do
      create_goal(ctx, "real-goal")
      create_plan(ctx, "p-ok", "real-goal")
      create_plan(ctx, "p-broken", "ghost-goal")
      create_todo(ctx, "t-ok", goal_slug: "real-goal")
      create_todo(ctx, "t-broken-goal", goal_slug: "ghost-goal")

      report = Brain.lint(ctx.id)

      broken_slugs = Enum.map(report.broken_goal_refs, & &1.slug)
      assert "p-broken" in broken_slugs
      assert "t-broken-goal" in broken_slugs
      refute "p-ok" in broken_slugs
      refute "t-ok" in broken_slugs
    end

    test "unplanned_todos lists todos with no plan and no goal", %{context: ctx} do
      create_goal(ctx, "g-unp")
      create_plan(ctx, "p-unp", nil)
      create_todo(ctx, "t-planned", plan_slug: "p-unp")
      create_todo(ctx, "t-goaled", goal_slug: "g-unp")
      create_todo(ctx, "t-lost", nil)

      report = Brain.lint(ctx.id)

      slugs = Enum.map(report.unplanned_todos, & &1.slug)
      assert "t-lost" in slugs
      refute "t-planned" in slugs
      refute "t-goaled" in slugs
    end

    test "lint still returns the original keys (orphans, stale, contested)", %{
      context: ctx
    } do
      report = Brain.lint(ctx.id)

      assert Map.has_key?(report, :orphans)
      assert Map.has_key?(report, :stale)
      assert Map.has_key?(report, :contested)
    end
  end
end
