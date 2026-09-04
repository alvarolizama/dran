defmodule Dran.ContractsStepsTest do
  @moduledoc """
  Wave C — Dran.Contracts ported to steps (plans/steps model): contract?,
  lint, render_brief, fingerprint, dependency_edges, dependency_states,
  prerequisite_ids, transitive_prereqs, ready?, levels and add_dependency
  (with the anti-cycle BFS) over %Dran.Step{} and step→step depends_on
  edges. Mold: test/dran/contracts_test.exs (task-based, untouched).
  """

  use Dran.DataCase, async: true

  alias Dran.{Contracts, Knowledge, Plans, Relation}

  setup do
    {:ok, ws} =
      Knowledge.create_workspace(%{
        name: "Contracts Steps WS #{System.unique_integer([:positive])}",
        slug: "contracts-steps-ws-#{System.unique_integer([:positive])}"
      })

    {:ok, plan} =
      Plans.create_plan(%{
        workspace_id: ws.id,
        title: "Plan Contracts Steps",
        slug: "plan-contracts-steps-#{System.unique_integer([:positive])}"
      })

    %{ws: ws, plan: plan}
  end

  describe "contract?/1 and lint/1 (steps)" do
    test "a step without meta.contract is not a contract", %{plan: plan} do
      step = create_step(plan, "Plain step")
      refute Contracts.contract?(step)
      assert {:error, [:no_contract]} = Contracts.lint(step)
    end

    test "a fully valid contract passes lint and contract?", %{plan: plan} do
      step = step_with_contract(plan, valid_contract())
      assert {:ok, []} = Contracts.lint(step)
      assert Contracts.contract?(step)
    end

    test "missing intent is rejected", %{plan: plan} do
      step = step_with_contract(plan, valid_contract() |> Map.delete("intent"))
      assert {:error, errors} = Contracts.lint(step)
      assert :intent in errors
      refute Contracts.contract?(step)
    end

    test "claims without verify are rejected", %{plan: plan} do
      contract =
        put_in(valid_contract()["claims"], [%{"id" => "P1", "claim" => "x", "verify" => ""}])

      step = step_with_contract(plan, contract)
      assert {:error, errors} = Contracts.lint(step)
      assert :claims in errors
    end

    test "gates without cmd are rejected", %{plan: plan} do
      contract =
        put_in(valid_contract()["gates"], [%{"name" => "g", "cmd" => "", "expect" => "ok"}])

      step = step_with_contract(plan, contract)
      assert {:error, errors} = Contracts.lint(step)
      assert :gates in errors
    end

    test "graph with a non-verb node is rejected", %{plan: plan} do
      contract =
        put_in(valid_contract()["graph"]["nodes"], [
          %{"id" => "S1", "verb" => "WRITE", "label" => "x"}
        ])

      step = step_with_contract(plan, contract)
      assert {:error, errors} = Contracts.lint(step)
      assert :graph_verbs in errors
    end

    test "graph without a VERIFY reachable node is rejected (funnel)", %{plan: plan} do
      contract =
        put_in(valid_contract()["graph"]["nodes"], [
          %{"id" => "S1", "verb" => "RUN", "label" => "x"},
          %{"id" => "S2", "verb" => "READ", "label" => "y"}
        ])

      contract =
        put_in(contract["graph"]["edges"], [%{"from" => "S1", "to" => "S2", "guard" => "yes"}])

      step = step_with_contract(plan, contract)
      assert {:error, errors} = Contracts.lint(step)
      assert :graph_funnel in errors
    end
  end

  describe "dependencies (step depends_on step)" do
    test "add_dependency creates a step→step edge with the step as dependent", %{plan: plan} do
      a = create_step(plan, "A")
      b = create_step(plan, "B")

      assert {:ok, %Relation{} = rel} = Contracts.add_dependency(b, a)
      assert rel.source_id == b.id
      assert rel.source_type == "step"
      assert rel.target_id == a.id
      assert rel.target_type == "step"
      assert rel.relation_type == "depends_on"

      assert Contracts.prerequisite_ids(b) == [a.id]
      assert Contracts.prerequisite_ids(a) == []

      # Definitional readiness: a (no prereqs) is ready; b (one prereq,
      # steps have no board status) is not.
      assert Contracts.ready?(a) == true
      assert Contracts.ready?(b) == false
    end

    test "self-dependency is rejected as a cycle", %{plan: plan} do
      a = create_step(plan, "A")
      assert {:error, :cycle} = Contracts.add_dependency(a, a)
    end

    test "cross-workspace dependency is rejected", %{ws: ws, plan: plan} do
      {:ok, ws2} =
        Knowledge.create_workspace(%{
          name: "Other Steps #{System.unique_integer([:positive])}",
          slug: "other-steps-ws-#{System.unique_integer([:positive])}"
        })

      {:ok, plan2} =
        Plans.create_plan(%{
          workspace_id: ws2.id,
          title: "Plan 2",
          slug: "plan-2-steps-#{System.unique_integer([:positive])}"
        })

      a = create_step(plan, "A")
      b = create_step(plan2, "B")
      assert a.workspace_id == ws.id
      assert {:error, :invalid} = Contracts.add_dependency(b, a)
    end

    test "creating a dependency that would close a cycle is rejected", %{plan: plan} do
      a = create_step(plan, "A")
      b = create_step(plan, "B")
      c = create_step(plan, "C")

      {:ok, _} = Contracts.add_dependency(b, a)
      {:ok, _} = Contracts.add_dependency(c, b)

      # a → c would close a→b→c→a
      assert {:error, :cycle} = Contracts.add_dependency(a, c)
    end

    test "transitive_prereqs handles diamonds (shared prereq)", %{plan: plan} do
      root = create_step(plan, "root")
      x = create_step(plan, "x")
      y = create_step(plan, "y")
      z = create_step(plan, "z")

      {:ok, _} = Contracts.add_dependency(x, root)
      {:ok, _} = Contracts.add_dependency(y, root)
      {:ok, _} = Contracts.add_dependency(z, x)
      {:ok, _} = Contracts.add_dependency(z, y)

      prereqs = Contracts.transitive_prereqs(z)
      assert Enum.sort(prereqs) == Enum.sort([root.id, x.id, y.id])
    end

    test "dependency_edges/2 excludes cross-plan edges (both endpoints in the set)", %{
      plan: plan
    } do
      a = create_step(plan, "A")
      b = create_step(plan, "B")
      outside = create_step(plan, "outside")

      # b depends on a (in-set) and on outside (target fuera del conjunto)
      {:ok, _} = Contracts.add_dependency(b, a)
      {:ok, _} = Contracts.add_dependency(b, outside)

      edges = Contracts.dependency_edges([a.id, b.id], :step)
      assert {b.id, a.id} in edges
      # La arista hacia un step fuera del conjunto no entra al DAG del plan
      refute {b.id, outside.id} in edges
      assert edges == [{b.id, a.id}]

      # Empty / non-list falla suave como el gemelo de tasks
      assert Contracts.dependency_edges([], :step) == []
      assert Contracts.dependency_edges(nil, :step) == []
    end

    test "dependency_states/2 counts external open prereqs as blocking", %{plan: plan} do
      a = create_step(plan, "A")
      b = create_step(plan, "B")
      outside = create_step(plan, "outside")

      {:ok, _} = Contracts.add_dependency(b, a)
      {:ok, _} = Contracts.add_dependency(b, outside)

      states = Contracts.dependency_states([a.id, b.id], :step)
      assert map_size(states) == 2
      assert states[a.id][:ready] == true
      assert states[a.id][:blocked_count] == 0
      assert states[b.id][:ready] == false
      assert states[b.id][:blocked_count] == 2

      # A diferencia de las tasks, un step prereq NUNCA llega a estado
      # terminal en la capa de definición (no hay board status): blocked no
      # se limpia aquí — la secuenciación por sesión es Executions (wave B).
      states2 = Contracts.dependency_states([b.id], :step)
      assert states2[b.id][:ready] == false
      assert states2[b.id][:blocked_count] == 2

      assert Contracts.dependency_states([], :step) == %{}
      assert Contracts.dependency_states(nil, :step) == %{}
    end
  end

  describe "levels/1 (topological columns over steps)" do
    test "linear chain produces increasing levels", %{plan: plan} do
      a = create_step(plan, "A")
      b = create_step(plan, "B")
      c = create_step(plan, "C")

      {:ok, _} = Contracts.add_dependency(b, a)
      {:ok, _} = Contracts.add_dependency(c, b)

      levels = Contracts.levels([a, b, c])

      a_level = Enum.find_index(levels, &(a.id in &1))
      b_level = Enum.find_index(levels, &(b.id in &1))
      c_level = Enum.find_index(levels, &(c.id in &1))

      assert a_level == 0
      assert b_level == 1
      assert c_level == 2
    end

    test "diamond yields two levels", %{plan: plan} do
      root = create_step(plan, "root")
      x = create_step(plan, "x")
      y = create_step(plan, "y")
      z = create_step(plan, "z")

      {:ok, _} = Contracts.add_dependency(x, root)
      {:ok, _} = Contracts.add_dependency(y, root)
      {:ok, _} = Contracts.add_dependency(z, x)
      {:ok, _} = Contracts.add_dependency(z, y)

      levels = Contracts.levels([root, x, y, z])

      assert Enum.find_index(levels, &(root.id in &1)) == 0
      assert Enum.find_index(levels, &(x.id in &1)) == 1
      assert Enum.find_index(levels, &(y.id in &1)) == 1
      assert Enum.find_index(levels, &(z.id in &1)) == 2
    end
  end

  describe "render_brief/1 (steps)" do
    test "renders a riel-brief packet with the 9 sections", %{plan: plan} do
      step = step_with_contract(plan, valid_contract())
      {:ok, brief} = Contracts.render_brief(step)

      for section <-
            ~w(# Task: ## Objective ## Claims ## Verification gates ## Execution graph ## Context ## Constraints ## Pre-registered claims ## Deliverable ## DO NOT) do
        assert brief =~ section
      end

      # Las secciones y sus ítems van en líneas separadas — nunca pegados
      # (regresión del join de listas anidadas en sections).
      assert brief =~ "\n## Claims\n"
      assert brief =~ "\n- **P1**"
      refute brief =~ "Claims- **"

      # El contexto apunta al step y su plan, no a una task
      assert brief =~ "see step #{step.id}"
      assert brief =~ "plan #{step.plan_id}"
      assert brief =~ "source: step:<id>"
    end

    test "returns error for a step without contract", %{plan: plan} do
      step = create_step(plan, "x")
      assert {:error, :no_contract} = Contracts.render_brief(step)
    end
  end

  describe "fingerprint/2 (steps)" do
    test "stable for an unchanged step, changes when contract or edges change", %{plan: plan} do
      step = step_with_contract(plan, valid_contract())
      fp = Contracts.fingerprint(step)
      assert is_binary(fp)
      assert fp == Contracts.fingerprint(step)

      # el contrato cambia → fingerprint cambia
      {:ok, step} =
        Plans.update_step(step, %{
          "meta" => %{"contract" => valid_contract() |> Map.put("intent", "Other intent")}
        })

      refute Contracts.fingerprint(step) == fp

      # una arista nueva (topologia del plan) → fingerprint cambia
      fp2 = Contracts.fingerprint(step)
      prereq = create_step(plan, "prereq")
      {:ok, _} = Contracts.add_dependency(step, prereq)
      refute Contracts.fingerprint(step) == fp2
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp create_step(plan, title) do
    slug = "#{String.downcase(title)}-#{System.unique_integer([:positive])}"

    {:ok, step} = Plans.create_step(plan, %{"title" => title, "slug" => slug})
    step
  end

  defp step_with_contract(plan, contract) do
    step = create_step(plan, "Contract step")
    {:ok, step} = Plans.update_step(step, %{"meta" => %{"contract" => contract}})
    step
  end

  defp valid_contract do
    %{
      "version" => 1,
      "status" => "active",
      "intent" => "Implement the contract linter",
      "claims" => [
        %{
          "id" => "P1",
          "claim" => "lint rejects malformed contracts",
          "verify" => "mix test test/dran/contracts_steps_test.exs"
        }
      ],
      "gates" => [
        %{
          "name" => "compile",
          "cmd" => "mix compile --warnings-as-errors",
          "expect" => "exit 0",
          "on_failure" => "fix warnings"
        }
      ],
      "graph" => %{
        "nodes" => [
          %{"id" => "S1", "verb" => "READ", "label" => "contracts.ex"},
          %{"id" => "S2", "verb" => "RUN", "label" => "mix test"},
          %{"id" => "G1", "verb" => "VERIFY", "label" => "tests green?"}
        ],
        "edges" => [
          %{"from" => "S1", "to" => "S2", "guard" => "yes"},
          %{"from" => "S2", "to" => "G1", "guard" => "yes"}
        ]
      },
      "context_snapshot" => [],
      "fingerprint" => "sha-abc",
      "model" => "test-model",
      "generated_by" => "test"
    }
  end
end
