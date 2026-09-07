defmodule Dran.WorkflowsTest do
  @moduledoc """
  Workflows/steps model (post-pivot 2026-09): CRUD of workflows and steps,
  slug uniqueness, position-based ordering/append, delete guards, node
  types, optional goal link. The wave A backfill migration tests are kept
  (they test the historical migration, which still runs from scratch).
  """

  use Dran.DataCase, async: false

  alias Dran.{Contracts, Goals, Knowledge, Relation, Repo, Task, Workflow, Workflows}

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
      # Auto-managed slug: a title change regenerates the slug.
      assert updated.slug == "b"
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
  # Edge menus: insert_step_between / link_step_between
  # ──────────────────────────────────────────────────────────────────────────

  describe "edge insertion (menú de arista)" do
    test "insert_step_between creates a NEW middle step and splits the edge", %{workspace: ws} do
      {:ok, plan} = Workflows.create_workflow(%{workspace_id: ws.id, title: "P", slug: "p-ins"})
      {:ok, a} = Workflows.create_step(plan, %{title: "A", slug: "a-ins"})
      {:ok, b} = Workflows.create_step(plan, %{title: "B", slug: "b-ins"})
      {:ok, _} = Contracts.add_dependency(b, a)

      assert {:ok, mid} =
               Workflows.insert_step_between(plan, b, a, %{"title" => "Nuevo", "slug" => "nuevo"})

      # A → nuevo → B: la arista original se partió y el nuevo está en medio.
      assert mid.title == "Nuevo"
      assert mid.id in Contracts.prerequisite_ids(Workflows.get_step!(b.id))
      assert a.id in Contracts.prerequisite_ids(Workflows.get_step!(mid.id))
      assert mid.id in Contracts.prerequisite_ids(Workflows.get_step!(b.id))
    end

    test "insert_step_between returns :missing_edge when the edge does not exist", %{
      workspace: ws
    } do
      {:ok, plan} = Workflows.create_workflow(%{workspace_id: ws.id, title: "P", slug: "p-ins2"})
      {:ok, a} = Workflows.create_step(plan, %{title: "A", slug: "a-ins2"})
      {:ok, b} = Workflows.create_step(plan, %{title: "B", slug: "b-ins2"})

      assert {:error, :missing_edge} =
               Workflows.insert_step_between(plan, b, a, %{"title" => "N", "slug" => "n2"})
    end

    test "insert_step_between rolls back when the new step is invalid", %{workspace: ws} do
      {:ok, plan} = Workflows.create_workflow(%{workspace_id: ws.id, title: "P", slug: "p-ins3"})
      {:ok, a} = Workflows.create_step(plan, %{title: "A", slug: "a-ins3"})
      {:ok, b} = Workflows.create_step(plan, %{title: "B", slug: "b-ins3"})
      {:ok, _} = Contracts.add_dependency(b, a)

      # Título >500 chars → changeset inválido → rollback de la transacción
      # entera (la arista original sobrevive intacta).
      assert {:error, %Ecto.Changeset{}} =
               Workflows.insert_step_between(plan, b, a, %{
                 "title" => String.duplicate("x", 501),
                 "slug" => ""
               })

      assert a.id in Contracts.prerequisite_ids(Workflows.get_step!(b.id))
      assert length(Workflows.list_steps(plan)) == 2
    end

    test "link_step_between places an EXISTING step in the middle of an edge", %{workspace: ws} do
      {:ok, plan} = Workflows.create_workflow(%{workspace_id: ws.id, title: "P", slug: "p-link"})
      {:ok, a} = Workflows.create_step(plan, %{title: "A", slug: "a-link"})
      {:ok, b} = Workflows.create_step(plan, %{title: "B", slug: "b-link"})
      {:ok, m} = Workflows.create_step(plan, %{title: "M", slug: "m-link"})
      {:ok, _} = Contracts.add_dependency(b, a)

      assert {:ok, _} = Workflows.link_step_between(b, a, m)

      # A → M → B: M quedó entre ambos.
      assert a.id in Contracts.prerequisite_ids(Workflows.get_step!(m.id))
      assert m.id in Contracts.prerequisite_ids(Workflows.get_step!(b.id))
      # Re-linkear tras el rewire: la arista a→b ya no existe → :missing_edge.
      assert {:error, :missing_edge} = Workflows.link_step_between(b, a, m)
    end

    test "link_step_between rejects middle == endpoint (self-edge)", %{workspace: ws} do
      {:ok, plan} = Workflows.create_workflow(%{workspace_id: ws.id, title: "P", slug: "p-link2"})
      {:ok, a} = Workflows.create_step(plan, %{title: "A", slug: "a-link2"})
      {:ok, b} = Workflows.create_step(plan, %{title: "B", slug: "b-link2"})
      {:ok, _} = Contracts.add_dependency(b, a)

      assert {:error, :invalid} = Workflows.link_step_between(b, a, a)
      assert {:error, :invalid} = Workflows.link_step_between(b, a, b)
    end

    test "link_step_between with a PRE-EXISTING diamond edge (middle already depends on prereq)",
         %{workspace: ws} do
      {:ok, plan} = Workflows.create_workflow(%{workspace_id: ws.id, title: "P", slug: "p-link3"})
      {:ok, a} = Workflows.create_step(plan, %{title: "A", slug: "a-link3"})
      {:ok, b} = Workflows.create_step(plan, %{title: "B", slug: "b-link3"})
      {:ok, m} = Workflows.create_step(plan, %{title: "M", slug: "m-link3"})
      {:ok, _} = Contracts.add_dependency(b, a)
      # Rombo: m ya depende de a. El rewire de b→a a b→m chocaría con el
      # índice único — el estado final ya es el deseado, no debe crashear.
      {:ok, _} = Contracts.add_dependency(m, a)

      assert {:ok, _} = Workflows.link_step_between(b, a, m)

      # Estado final: A → M → B, con UNA sola arista hacia B (sin duplicados
      # ni fila huérfana del rombo).
      assert Contracts.prerequisite_ids(Workflows.get_step!(m.id)) == [a.id]
      assert Contracts.prerequisite_ids(Workflows.get_step!(b.id)) == [m.id]
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

    test "kind is editable before sessions and locked after", %{workspace: ws} do
      {:ok, plan} =
        Workflows.create_workflow(%{workspace_id: ws.id, title: "K", slug: "k"})

      # Pre-execution: the kind decision is exactly what updates before any
      # session exist.
      assert {:ok, one_shot} = Workflows.update_workflow(plan, %{"kind" => "one_shot"})
      assert one_shot.kind == "one_shot"

      {:ok, _} = Workflows.create_step(one_shot, %{title: "S", slug: "s"})
      {:ok, _session} = Dran.Executions.open_session(one_shot)

      # A session now exists: the kind is history — a CHANGE is refused...
      assert {:error, :kind_locked} =
               Workflows.update_workflow(one_shot, %{"kind" => "evergreen"})

      # ...while a same-kind write (forms always submit the select) passes,
      # and the rest of the fields stay editable.
      assert {:ok, renamed} =
               Workflows.update_workflow(one_shot, %{"kind" => "one_shot", "title" => "K2"})

      assert renamed.title == "K2"
      assert renamed.kind == "one_shot"
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
  # Canvas positions (free layout in pos_x/pos_y)
  # ──────────────────────────────────────────────────────────────────────────

  describe "canvas positions (move_step / repack_layout)" do
    test "move_step persists pos_x/pos_y and preserves the contract", %{workspace: ws} do
      {:ok, plan} =
        Workflows.create_workflow(%{workspace_id: ws.id, title: "P", slug: "p-canvas"})

      {:ok, step} = Workflows.create_step(plan, %{title: "S", slug: "s-canvas"})

      {:ok, contracted} = Workflows.update_step(step, %{"intent" => "x"})

      assert {:ok, moved} = Workflows.move_step(contracted, 120, 240)
      assert {moved.pos_x, moved.pos_y} == {120, 240}
      assert moved.intent == "x"
    end

    test "move_step rejects negative or non-integer coordinates", %{workspace: ws} do
      {:ok, plan} =
        Workflows.create_workflow(%{workspace_id: ws.id, title: "P", slug: "p-canvas-2"})

      {:ok, step} = Workflows.create_step(plan, %{title: "S", slug: "s-canvas-2"})

      assert_raise FunctionClauseError, fn -> Workflows.move_step(step, -10, 0) end
      assert_raise FunctionClauseError, fn -> Workflows.move_step(step, 1.5, 0) end
    end

    test "repack_layout clears pos_x/pos_y of every step and keeps contracts", %{workspace: ws} do
      {:ok, plan} =
        Workflows.create_workflow(%{workspace_id: ws.id, title: "P", slug: "p-canvas-3"})

      {:ok, s1} = Workflows.create_step(plan, %{title: "S1", slug: "s1-canvas"})
      {:ok, s2} = Workflows.create_step(plan, %{title: "S2", slug: "s2-canvas"})

      {:ok, _} = Workflows.update_step(s1, %{"intent" => "y"})
      {:ok, s1} = Workflows.move_step(s1, 10, 20)
      {:ok, _} = Workflows.move_step(s2, 30, 40)

      assert {:ok, _} = Workflows.repack_layout(plan)

      steps = Workflows.list_steps(plan)
      assert Enum.all?(steps, &is_nil(&1.pos_x))

      by_id = Map.new(steps, &{&1.id, &1})
      assert by_id[s1.id].intent == "y"
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
