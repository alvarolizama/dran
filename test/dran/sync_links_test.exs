defmodule Dran.SyncLinksTest do
  use Dran.DataCase, async: false

  # Tests for the new sync_todo_links/2 behaviour (plan §3, task 2.7).
  #
  # Unlike the old sync_planning_relations/2, the new sync has NO precedence
  # between project_slug / goal_slug / plan_slug: each is materialized
  # independently. It also recomputes derived health on the parent project
  # (when a goal's health changes) and derived progress on the parent goal
  # (when a todo's kanban_status changes).
  #
  # These tests run against the spec; if brain.ex still has the old
  # sync_planning_relations/2 (other subagent working in parallel), the
  # "no precedence" and "recompute" tests will fail — that is expected.

  alias Dran.Brain

  # Same setup as brain_test / planning_hierarchy_test: disable inference so
  # create_page doesn't call external embedding/rerank APIs, and ensure a
  # "personal" context exists.
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

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp create_project(ctx, slug, opts \\ []) do
    meta =
      %{
        "status" => Keyword.get(opts, :status, "active"),
        "health" => Keyword.get(opts, :health, "green"),
        "health_source" => Keyword.get(opts, :health_source, "derived"),
        "priority" => Keyword.get(opts, :priority, "medium")
      }
      |> maybe_put("progress_manual", Keyword.get(opts, :progress_manual))

    {:ok, project} =
      Brain.create_page(%{
        context_id: ctx.id,
        title: slug,
        slug: slug,
        page_type: "project",
        body: "",
        meta: meta
      })

    project
  end

  defp create_goal(ctx, slug, opts \\ []) do
    meta =
      %{"health" => Keyword.get(opts, :health, "green")}
      |> maybe_put("project_slug", Keyword.get(opts, :project_slug))
      |> maybe_put("progress", Keyword.get(opts, :progress))
      |> maybe_put("progress_manual", Keyword.get(opts, :progress_manual))

    {:ok, goal} =
      Brain.create_page(%{
        context_id: ctx.id,
        title: slug,
        slug: slug,
        page_type: "goal",
        body: "",
        meta: meta
      })

    goal
  end

  defp create_plan(ctx, slug, opts \\ []) do
    meta =
      %{
        "status" => Keyword.get(opts, :status, "draft"),
        "horizon" => Keyword.get(opts, :horizon, "weekly")
      }
      |> maybe_put("goal_slug", Keyword.get(opts, :goal_slug))
      |> maybe_put("project_slug", Keyword.get(opts, :project_slug))

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
    meta =
      %{"kanban_status" => Keyword.get(opts, :kanban_status, "backlog"), "priority" => "medium"}
      |> maybe_put("plan_slug", Keyword.get(opts, :plan_slug))
      |> maybe_put("goal_slug", Keyword.get(opts, :goal_slug))
      |> maybe_put("project_slug", Keyword.get(opts, :project_slug))

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

  # Collect slugs of outbound part_of targets for a page (as stored in DB).
  defp part_of_targets(page) do
    page.id
    |> Brain.list_relations_for_page()
    |> Map.get(:outbound, [])
    |> Enum.filter(&(&1.relation_type == "part_of"))
    |> Enum.map(& &1.target.slug)
    |> Enum.sort()
  end

  # Reload a page fresh from the DB (so we see meta changes applied by
  # recompute_project_health / recompute_goal_progress via update_page).
  defp reload(page) do
    Brain.get_page_by_slug(page.slug, page.context_id)
  end

  defp meta_get(page, key), do: page.meta && Map.get(page.meta, key)

  # ── 1. Todo with only project_slug ───────────────────────────────────────

  describe "sync_todo_links: project_slug only" do
    test "creates part_of todo→project only", %{context: ctx} do
      create_project(ctx, "p1")
      todo = create_todo(ctx, "t1", project_slug: "p1")

      assert part_of_targets(todo) == ["p1"]
    end
  end

  # ── 2. Todo with project_slug + goal_slug (no precedence — new behaviour) ─

  describe "sync_todo_links: project + goal (no precedence)" do
    test "creates BOTH part_of todo→project and todo→goal", %{context: ctx} do
      create_project(ctx, "proj-a")
      create_goal(ctx, "goal-a")
      todo = create_todo(ctx, "t2", project_slug: "proj-a", goal_slug: "goal-a")

      targets = part_of_targets(todo)
      assert "proj-a" in targets
      assert "goal-a" in targets
      assert length(targets) == 2
    end
  end

  # ── 3. Todo with all three slugs ─────────────────────────────────────────

  describe "sync_todo_links: three slugs" do
    test "creates three part_of relations", %{context: ctx} do
      create_project(ctx, "proj-b")
      create_goal(ctx, "goal-b")
      create_plan(ctx, "plan-b")
      todo = create_todo(ctx, "t3", project_slug: "proj-b", goal_slug: "goal-b", plan_slug: "plan-b")

      targets = part_of_targets(todo)
      assert Enum.sort(targets) == ["goal-b", "plan-b", "proj-b"]
      assert length(targets) == 3
    end
  end

  # ── 4. Todo updates plan_slug → goal_slug (project intact) ───────────────

  describe "sync_todo_links: plan→goal switch keeps project" do
    test "removes part_of→plan, adds part_of→goal, project untouched", %{context: ctx} do
      create_project(ctx, "proj-c")
      create_plan(ctx, "plan-c")
      create_goal(ctx, "goal-c")

      todo =
        create_todo(ctx, "t4",
          project_slug: "proj-c",
          plan_slug: "plan-c"
        )

      # Sanity: project + plan part_of exist.
      initial = part_of_targets(todo)
      assert "proj-c" in initial
      assert "plan-c" in initial

      # Switch: drop plan_slug, add goal_slug, keep project_slug.
      {:ok, updated} =
        Brain.update_page(todo, %{
          meta: %{
            "kanban_status" => "backlog",
            "priority" => "medium",
            "project_slug" => "proj-c",
            "goal_slug" => "goal-c"
          }
        })

      targets = part_of_targets(updated)
      assert "proj-c" in targets, "project part_of must survive the update"
      assert "goal-c" in targets, "goal part_of must be added"
      refute "plan-c" in targets, "plan part_of must be removed"
    end
  end

  # ── 5. Todo drops all slugs ──────────────────────────────────────────────

  describe "sync_todo_links: drop all slugs" do
    test "removes every part_of relation", %{context: ctx} do
      create_project(ctx, "proj-d")
      create_goal(ctx, "goal-d")
      create_plan(ctx, "plan-d")

      todo =
        create_todo(ctx, "t5",
          project_slug: "proj-d",
          goal_slug: "goal-d",
          plan_slug: "plan-d"
        )

      # Sanity: three part_of exist.
      assert length(part_of_targets(todo)) == 3

      {:ok, updated} =
        Brain.update_page(todo, %{
          meta: %{
            "kanban_status" => "backlog",
            "priority" => "medium"
          }
        })

      assert part_of_targets(updated) == []
    end
  end

  # ── 6. Goal health edit → recompute_project_health ───────────────────────

  describe "recompute_project_health" do
    test "project health is the floored average of its goals' healths", %{context: ctx} do
      # Project with 2 goals. Healths: green (3) + red (1) = avg 2.0 → yellow.
      create_project(ctx, "proj-h")
      _g1 = create_goal(ctx, "g-h1", project_slug: "proj-h", health: "green")
      g2 = create_goal(ctx, "g-h2", project_slug: "proj-h", health: "red")

      # The project's health should have been derived after the goals were
      # created. Reload and check.
      proj = reload(Brain.get_page_by_slug("proj-h", ctx.id))
      # green(3) + red(1) = avg 2.0 → floor(2.0) = 2 → yellow
      assert meta_get(proj, "health") == "yellow"
      assert meta_get(proj, "health_source") == "derived"

      # Edit the red goal's health to green: green(3) + green(3) = avg 3.0 → green.
      {:ok, _} =
        Brain.update_page(g2, %{
          meta: %{"health" => "green", "project_slug" => "proj-h"}
        })

      proj2 = reload(Brain.get_page_by_slug("proj-h", ctx.id))
      assert meta_get(proj2, "health") == "green"
    end

    test "floor semantics: green+yellow+red → avg 2.0 → yellow", %{context: ctx} do
      create_project(ctx, "proj-h2")
      create_goal(ctx, "g-mix1", project_slug: "proj-h2", health: "green")
      create_goal(ctx, "g-mix2", project_slug: "proj-h2", health: "yellow")
      create_goal(ctx, "g-mix3", project_slug: "proj-h2", health: "red")

      proj = reload(Brain.get_page_by_slug("proj-h2", ctx.id))
      # (3 + 2 + 1) / 3 = 2.0 → floor → 2 → yellow
      assert meta_get(proj, "health") == "yellow"
    end
  end

  # ── 7. Project with health_source: "manual" — goal edits don't override ─

  describe "recompute_project_health: manual override" do
    test "editing a linked goal does NOT change the project's health", %{context: ctx} do
      create_project(ctx, "proj-man", health: "red", health_source: "manual")
      g = create_goal(ctx, "g-man", project_slug: "proj-man", health: "green")

      # Project health stays at the manually-set "red".
      proj = reload(Brain.get_page_by_slug("proj-man", ctx.id))
      assert meta_get(proj, "health") == "red"

      # Edit the goal's health — must not propagate.
      {:ok, _} =
        Brain.update_page(g, %{
          meta: %{"health" => "yellow", "project_slug" => "proj-man"}
        })

      proj2 = reload(Brain.get_page_by_slug("proj-man", ctx.id))
      assert meta_get(proj2, "health") == "red"
      assert meta_get(proj2, "health_source") == "manual"
    end
  end

  # ── 8. Todo kanban_status → recompute_goal_progress ──────────────────────

  describe "recompute_goal_progress" do
    test "goal progress = done / (total non-cancelled todos)", %{context: ctx} do
      create_goal(ctx, "goal-prog")
      # 4 todos: 1 done, 1 in_progress, 1 backlog, 1 cancelled.
      # relevant (non-cancelled) = 3, done = 1 → 1/3 ≈ 0.33
      create_todo(ctx, "tp-1", goal_slug: "goal-prog", kanban_status: "done")
      create_todo(ctx, "tp-2", goal_slug: "goal-prog", kanban_status: "in_progress")
      create_todo(ctx, "tp-3", goal_slug: "goal-prog", kanban_status: "backlog")
      create_todo(ctx, "tp-4", goal_slug: "goal-prog", kanban_status: "cancelled")

      goal = reload(Brain.get_page_by_slug("goal-prog", ctx.id))
      progress = meta_get(goal, "progress")
      assert is_float(progress) or is_integer(progress)
      # 1/3 rounded to 2 decimals = 0.33
      assert_in_delta progress, 0.33, 0.01
    end

    test "editing a todo to done updates the goal's progress", %{context: ctx} do
      create_goal(ctx, "goal-prog2")
      t = create_todo(ctx, "tp-edit", goal_slug: "goal-prog2", kanban_status: "backlog")

      goal0 = reload(Brain.get_page_by_slug("goal-prog2", ctx.id))
      assert meta_get(goal0, "progress") == 0.0 or is_nil(meta_get(goal0, "progress"))

      {:ok, _} =
        Brain.update_page(t, %{
          meta: %{
            "kanban_status" => "done",
            "priority" => "medium",
            "goal_slug" => "goal-prog2"
          }
        })

      goal1 = reload(Brain.get_page_by_slug("goal-prog2", ctx.id))
      # 1 done / 1 relevant = 1.0
      assert_in_delta meta_get(goal1, "progress") || 0.0, 1.0, 0.01
    end
  end

  # ── 9. Goal with progress_manual: true — recompute does not override ────

  describe "recompute_goal_progress: manual override" do
    test "progress_manual goal keeps its progress value", %{context: ctx} do
      create_goal(ctx, "goal-pm", progress: 0.5, progress_manual: true)
      create_todo(ctx, "tpm-1", goal_slug: "goal-pm", kanban_status: "done")
      create_todo(ctx, "tpm-2", goal_slug: "goal-pm", kanban_status: "backlog")

      # Even though derived progress would be 0.5 (1/2), the manual flag
      # must keep it at the user-set value.
      goal = reload(Brain.get_page_by_slug("goal-pm", ctx.id))
      assert meta_get(goal, "progress") == 0.5
      assert meta_get(goal, "progress_manual") == true
    end
  end

  # ── 10. Non-existent target slug — no relation, no crash ─────────────────

  describe "sync_todo_links: missing target" do
    test "ghost project_slug does not create a relation and does not crash", %{context: ctx} do
      todo = create_todo(ctx, "t-ghost", project_slug: "no-such-project")

      assert part_of_targets(todo) == []
    end

    test "ghost goal_slug + plan_slug also produce no relation", %{context: ctx} do
      todo =
        create_todo(ctx, "t-ghost2", goal_slug: "no-such-goal", plan_slug: "no-such-plan")

      assert part_of_targets(todo) == []
    end
  end
end
