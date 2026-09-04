defmodule Dran.WorkflowsTest do
  @moduledoc """
  Workflows/steps model (post-pivot 2026-09): CRUD of workflows and steps,
  slug uniqueness, position-based ordering/append, delete guards, node
  types, optional goal link. The wave A backfill migration tests are kept
  (they test the historical migration, which still runs from scratch).
  """

  use Dran.DataCase, async: false

  alias Dran.{Goals, Knowledge, Relation, Repo, Task, Workflow, Workflows}

  setup do
    %{workspace: ensure_workspace!()}
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Plan CRUD
  # ──────────────────────────────────────────────────────────────────────────

  describe "plan CRUD" do
    test "create_workflow/1 creates a plan and get_workflow_by_slug/2 finds it", %{workspace: ws} do
      assert {:ok, %Workflow{} = plan} =
               Workflows.create_workflow(%{
                 workspace_id: ws.id,
                 title: "Plan A",
                 slug: "plan-a",
                 body: "long"
               })

      assert plan.title == "Plan A"
      assert plan.body == "long"

      assert Workflows.get_workflow_by_slug("plan-a", ws.id).id == plan.id
    end

    test "update_workflow/2 updates fields", %{workspace: ws} do
      {:ok, plan} = Workflows.create_workflow(%{workspace_id: ws.id, title: "A", slug: "a"})

      assert {:ok, updated} = Workflows.update_workflow(plan, %{title: "B", body: "b"})
      assert updated.title == "B"
      assert updated.body == "b"
      assert updated.slug == "a"
    end

    test "list_plans/1 lists plans of a workspace", %{workspace: ws} do
      {:ok, _} = Workflows.create_workflow(%{workspace_id: ws.id, title: "A", slug: "a"})
      {:ok, _} = Workflows.create_workflow(%{workspace_id: ws.id, title: "B", slug: "b"})

      assert length(Workflows.list_workflows(ws.id)) == 2
    end

    test "slug is unique per workspace", %{workspace: ws} do
      {:ok, _} = Workflows.create_workflow(%{workspace_id: ws.id, title: "A", slug: "dup"})

      assert {:error, changeset} =
               Workflows.create_workflow(%{workspace_id: ws.id, title: "B", slug: "dup"})

      assert "has already been taken" in changeset_errors(changeset)
    end

    test "list_workflows/2 filters by kind (list) and archived", %{workspace: ws} do
      {:ok, _} =
        Workflows.create_workflow(%{
          workspace_id: ws.id,
          title: "A",
          slug: "a",
          kind: "evergreen"
        })

      {:ok, one_shot} =
        Workflows.create_workflow(%{workspace_id: ws.id, title: "B", slug: "b", kind: "one_shot"})

      assert length(Workflows.list_workflows(ws.id)) == 2
      assert [%Workflow{}] = flows = Workflows.list_workflows(ws.id, kind: ["evergreen"])
      assert hd(flows).kind == "evergreen"

      assert [%Workflow{}] = one_shots = Workflows.list_workflows(ws.id, kind: ["one_shot"])
      assert hd(one_shots).id == one_shot.id

      # Both kinds selected returns both.
      assert length(Workflows.list_workflows(ws.id, kind: ["evergreen", "one_shot"])) == 2

      # Archive one — leaves the default list, appears with archived: true.
      {:ok, one_shot} = Workflows.archive_workflow(one_shot)

      assert length(Workflows.list_workflows(ws.id)) == 1
      assert [%Workflow{}] = archived = Workflows.list_workflows(ws.id, archived: true)
      assert hd(archived).id == one_shot.id

      # Unarchive restores it to the default list.
      {:ok, _} = Workflows.unarchive_workflow(one_shot)
      assert length(Workflows.list_workflows(ws.id)) == 2
      assert Workflows.list_workflows(ws.id, archived: true) == []
    end

    test "list_workflows/2 filters by status (draft/active)", %{workspace: ws} do
      {:ok, _} =
        Workflows.create_workflow(%{workspace_id: ws.id, title: "A", slug: "a", status: "draft"})

      {:ok, active} =
        Workflows.create_workflow(%{workspace_id: ws.id, title: "B", slug: "b", status: "active"})

      assert length(Workflows.list_workflows(ws.id)) == 2
      assert [%Workflow{}] = drafts = Workflows.list_workflows(ws.id, status: ["draft"])
      assert hd(drafts).status == "draft"

      assert [%Workflow{}] = actives = Workflows.list_workflows(ws.id, status: ["active"])
      assert hd(actives).id == active.id

      # Both selected → both returned; bogus values are dropped.
      assert length(Workflows.list_workflows(ws.id, status: ["draft", "active"])) == 2
      assert length(Workflows.list_workflows(ws.id, status: ["bogus"])) == 2
      assert length(Workflows.list_workflows(ws.id, status: ["archived"])) == 2

      # Status filter composes with kind filter.
      assert Workflows.list_workflows(ws.id, kind: ["one_shot"], status: ["active"]) == []

      {:ok, _} =
        Workflows.create_workflow(%{
          workspace_id: ws.id,
          title: "C",
          slug: "c",
          status: "active",
          kind: "one_shot"
        })

      assert [%Workflow{}] =
               both = Workflows.list_workflows(ws.id, kind: ["one_shot"], status: ["active"])

      assert hd(both).slug == "c"
    end

    test "same slug allowed in different workspaces", %{workspace: ws} do
      other = ensure_workspace!("other-ws", "Other WS")
      {:ok, _} = Workflows.create_workflow(%{workspace_id: ws.id, title: "A", slug: "dup"})

      assert {:ok, _} =
               Workflows.create_workflow(%{workspace_id: other.id, title: "B", slug: "dup"})
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Step CRUD
  # ──────────────────────────────────────────────────────────────────────────

  describe "step CRUD" do
    setup %{workspace: ws} do
      {:ok, plan} = Workflows.create_workflow(%{workspace_id: ws.id, title: "Plan", slug: "plan"})
      %{plan: plan}
    end

    test "create_step/2 appends at position max+100", %{plan: plan} do
      {:ok, s1} = Workflows.create_step(plan, %{title: "Step 1", slug: "step-1"})
      {:ok, s2} = Workflows.create_step(plan, %{title: "Step 2", slug: "step-2"})

      assert s1.position == 100
      assert s2.position == 200
      assert [s1.id, s2.id] == Enum.map(Workflows.list_steps(plan), & &1.id)
    end

    test "create_step/2 copies workspace and plan from the plan", %{workspace: ws, plan: plan} do
      {:ok, step} = Workflows.create_step(plan, %{title: "S", slug: "s"})
      assert step.workflow_id == plan.id
      assert step.workspace_id == ws.id
    end

    test "update_step/2 updates and keeps ordering", %{plan: plan} do
      {:ok, s1} = Workflows.create_step(plan, %{title: "S1", slug: "s1"})

      assert {:ok, updated} = Workflows.update_step(s1, %{title: "Renamed", position: 50})
      assert updated.title == "Renamed"
      assert updated.position == 50

      assert [updated.id] == Enum.map(Workflows.list_steps(plan), & &1.id)
    end

    test "step slug is unique per workspace", %{plan: plan} do
      {:ok, _} = Workflows.create_step(plan, %{title: "S1", slug: "dups"})

      assert {:error, changeset} = Workflows.create_step(plan, %{title: "S2", slug: "dups"})
      assert "has already been taken" in changeset_errors(changeset)
    end

    test "delete_step/1 deletes a step without open runs", %{plan: plan} do
      {:ok, step} = Workflows.create_step(plan, %{title: "S", slug: "s"})

      assert {:ok, %Dran.Step{}} = Workflows.delete_step(step)
      assert Workflows.list_steps(plan) == []
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Delete guards
  # ──────────────────────────────────────────────────────────────────────────

  describe "delete guards" do
    test "delete_workflow/1 succeeds when there are no sessions", %{workspace: ws} do
      {:ok, plan} =
        Workflows.create_workflow(%{workspace_id: ws.id, title: "Plan", slug: "no-sessions"})

      {:ok, step} = Workflows.create_step(plan, %{title: "S", slug: "s"})
      {:ok, step2} = Workflows.create_step(plan, %{title: "S2", slug: "s2"})

      assert {:ok, _} =
               Knowledge.create_relation(%{
                 source_id: step.id,
                 source_type: "step",
                 target_id: step2.id,
                 target_type: "step",
                 relation_type: "depends_on"
               })

      assert {:ok, deleted} = Workflows.delete_workflow(plan)
      assert deleted.id == plan.id
      # steps and their polymorphic edges are gone
      assert Repo.all(from(s in Dran.Step, where: s.workflow_id == ^plan.id)) == []
      assert Repo.all(from(r in Relation, where: r.source_type == "step")) == []
    end

    test "delete_workflow/1 refuses when the workflow has sessions", %{workspace: ws} do
      {:ok, plan} = Workflows.create_workflow(%{workspace_id: ws.id, title: "P", slug: "p"})
      {:ok, _} = Workflows.create_step(plan, %{title: "S", slug: "s"})
      {:ok, _session} = Dran.Executions.open_session(plan)

      assert {:error, :has_sessions} = Workflows.delete_workflow(plan)
    end

    test "delete_step/1 refuses when the step has open runs", %{workspace: ws} do
      {:ok, plan} = Workflows.create_workflow(%{workspace_id: ws.id, title: "P", slug: "p"})
      {:ok, step} = Workflows.create_step(plan, %{title: "S", slug: "s"})
      {:ok, _session} = Dran.Executions.open_session(plan)
      run = Dran.Repo.get_by!(Dran.Run, step_id: step.id)

      assert {:error, :has_open_runs} = Workflows.delete_step(step)
      assert Dran.Repo.reload!(run)
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # New relation types (P3)
  # ──────────────────────────────────────────────────────────────────────────

  describe "relation types" do
    test "step node type and step depends_on step edges are accepted", %{workspace: ws} do
      {:ok, plan} = Workflows.create_workflow(%{workspace_id: ws.id, title: "P", slug: "p"})
      {:ok, step} = Workflows.create_step(plan, %{title: "S", slug: "s"})

      assert "step" in Relation.node_types()
      refute "plan" in Relation.node_types()

      # step depends_on step (the workflow DAG edges)
      {:ok, step2} = Workflows.create_step(plan, %{title: "S2", slug: "s2"})

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
  # Helpers
  # ──────────────────────────────────────────────────────────────────────────

  defp changeset_errors(changeset) do
    changeset.errors
    |> Enum.flat_map(fn {_field, {msg, _opts}} -> [msg] end)
  end
end
