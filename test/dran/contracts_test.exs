defmodule Dran.ContractsTest do
  use Dran.DataCase, async: true

  alias Dran.{Contracts, Knowledge, Repo, Task, Tasks}

  setup do
    {:ok, ws} =
      Knowledge.create_workspace(%{
        name: "Contracts WS #{System.unique_integer([:positive])}",
        slug: "contracts-ws-#{System.unique_integer([:positive])}"
      })

    {:ok, ws: ws}
  end

  describe "contract?/1 and lint/1" do
    test "a task without meta.contract is not a contract", %{ws: ws} do
      {:ok, task} = Tasks.create_task(%{"workspace_id" => ws.id, "title" => "Plain task"})
      refute Contracts.contract?(task)
      assert {:error, [:no_contract]} = Contracts.lint(task)
    end

    test "a fully valid contract passes lint and contract?", %{ws: ws} do
      task = task_with_contract(ws.id, valid_contract())
      assert {:ok, []} = Contracts.lint(task)
      assert Contracts.contract?(task)
    end

    test "missing intent is rejected", %{ws: ws} do
      task = task_with_contract(ws.id, valid_contract() |> Map.delete("intent"))
      assert {:error, errors} = Contracts.lint(task)
      assert :intent in errors
      refute Contracts.contract?(task)
    end

    test "claims without verify are rejected", %{ws: ws} do
      contract =
        put_in(valid_contract()["claims"], [%{"id" => "P1", "claim" => "x", "verify" => ""}])

      task = task_with_contract(ws.id, contract)
      assert {:error, errors} = Contracts.lint(task)
      assert :claims in errors
    end

    test "gates without cmd are rejected", %{ws: ws} do
      contract =
        put_in(valid_contract()["gates"], [%{"name" => "g", "cmd" => "", "expect" => "ok"}])

      task = task_with_contract(ws.id, contract)
      assert {:error, errors} = Contracts.lint(task)
      assert :gates in errors
    end

    test "graph with a non-verb node is rejected", %{ws: ws} do
      contract =
        put_in(valid_contract()["graph"]["nodes"], [
          %{"id" => "S1", "verb" => "WRITE", "label" => "x"}
        ])

      task = task_with_contract(ws.id, contract)
      assert {:error, errors} = Contracts.lint(task)
      assert :graph_verbs in errors
    end

    test "graph without a VERIFY reachable node is rejected (funnel)", %{ws: ws} do
      contract =
        put_in(valid_contract()["graph"]["nodes"], [
          %{"id" => "S1", "verb" => "RUN", "label" => "x"},
          %{"id" => "S2", "verb" => "READ", "label" => "y"}
        ])

      contract =
        put_in(contract["graph"]["edges"], [%{"from" => "S1", "to" => "S2", "guard" => "yes"}])

      task = task_with_contract(ws.id, contract)
      assert {:error, errors} = Contracts.lint(task)
      assert :graph_funnel in errors
    end
  end

  describe "dependencies (depends_on)" do
    test "add_dependency creates a task→task edge and ready? reflects status", %{ws: ws} do
      {:ok, a} = Tasks.create_task(%{"workspace_id" => ws.id, "title" => "A"})
      {:ok, b} = Tasks.create_task(%{"workspace_id" => ws.id, "title" => "B"})

      assert {:ok, _} = Contracts.add_dependency(b, a)
      assert Contracts.ready?(b) == false
      assert Contracts.blocking_prereqs(b) == [a.id]

      {:ok, _} = Tasks.update_task(a, %{"status" => "done"})
      assert Contracts.ready?(b) == true
      assert Contracts.blocking_prereqs(b) == []
    end

    test "self-dependency is rejected as a cycle", %{ws: ws} do
      {:ok, a} = Tasks.create_task(%{"workspace_id" => ws.id, "title" => "A"})
      assert {:error, :cycle} = Contracts.add_dependency(a, a)
    end

    test "cross-workspace dependency is rejected", %{ws: ws} do
      {:ok, ws2} = Knowledge.create_workspace(%{name: "Other", slug: "other-ws"})
      {:ok, a} = Tasks.create_task(%{"workspace_id" => ws.id, "title" => "A"})
      {:ok, b} = Tasks.create_task(%{"workspace_id" => ws2.id, "title" => "B"})
      assert {:error, :invalid} = Contracts.add_dependency(a, b)
    end

    test "creating a dependency that would close a cycle is rejected", %{ws: ws} do
      {:ok, a} = Tasks.create_task(%{"workspace_id" => ws.id, "title" => "A"})
      {:ok, b} = Tasks.create_task(%{"workspace_id" => ws.id, "title" => "B"})
      {:ok, c} = Tasks.create_task(%{"workspace_id" => ws.id, "title" => "C"})

      {:ok, _} = Contracts.add_dependency(b, a)
      {:ok, _} = Contracts.add_dependency(c, b)

      # a → c would close a→b→c→a
      assert {:error, :cycle} = Contracts.add_dependency(a, c)
    end

    test "transitive_prereqs handles diamonds (shared prereq)", %{ws: ws} do
      {:ok, root} = Tasks.create_task(%{"workspace_id" => ws.id, "title" => "root"})
      {:ok, x} = Tasks.create_task(%{"workspace_id" => ws.id, "title" => "x"})
      {:ok, y} = Tasks.create_task(%{"workspace_id" => ws.id, "title" => "y"})
      {:ok, z} = Tasks.create_task(%{"workspace_id" => ws.id, "title" => "z"})

      {:ok, _} = Contracts.add_dependency(x, root)
      {:ok, _} = Contracts.add_dependency(y, root)
      {:ok, _} = Contracts.add_dependency(z, x)
      {:ok, _} = Contracts.add_dependency(z, y)

      prereqs = Contracts.transitive_prereqs(z)
      assert Enum.sort(prereqs) == Enum.sort([root.id, x.id, y.id])
    end
  end

  describe "levels/1 (topological columns)" do
    test "linear chain produces increasing levels", %{ws: ws} do
      {:ok, a} = Tasks.create_task(%{"workspace_id" => ws.id, "title" => "A"})
      {:ok, b} = Tasks.create_task(%{"workspace_id" => ws.id, "title" => "B"})
      {:ok, c} = Tasks.create_task(%{"workspace_id" => ws.id, "title" => "C"})

      {:ok, _} = Contracts.add_dependency(b, a)
      {:ok, _} = Contracts.add_dependency(c, b)

      tasks = [a, b, c]
      levels = Contracts.levels(tasks)

      a_level = Enum.find_index(levels, &(a.id in &1))
      b_level = Enum.find_index(levels, &(b.id in &1))
      c_level = Enum.find_index(levels, &(c.id in &1))

      assert a_level == 0
      assert b_level == 1
      assert c_level == 2
    end

    test "diamond yields two levels", %{ws: ws} do
      {:ok, root} = Tasks.create_task(%{"workspace_id" => ws.id, "title" => "root"})
      {:ok, x} = Tasks.create_task(%{"workspace_id" => ws.id, "title" => "x"})
      {:ok, y} = Tasks.create_task(%{"workspace_id" => ws.id, "title" => "y"})
      {:ok, z} = Tasks.create_task(%{"workspace_id" => ws.id, "title" => "z"})

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

  describe "render_brief/1" do
    test "renders a riel-brief packet with the 9 sections", %{ws: ws} do
      task = task_with_contract(ws.id, valid_contract())
      {:ok, brief} = Contracts.render_brief(task)

      for section <-
            ~w(# Task: ## Objective ## Claims ## Verification gates ## Execution graph ## Context ## Constraints ## Pre-registered claims ## Deliverable ## DO NOT) do
        assert brief =~ section
      end

      # Las secciones y sus ítems van en líneas separadas — nunca pegados
      # (regresión del join de listas anidadas en sections).
      assert brief =~ "\n## Claims\n"
      assert brief =~ "\n- **P1**"
      refute brief =~ "Claims- **"
    end

    test "returns error for a task without contract", %{ws: ws} do
      {:ok, task} = Tasks.create_task(%{"workspace_id" => ws.id, "title" => "x"})
      assert {:error, :no_contract} = Contracts.render_brief(task)
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp task_with_contract(workspace_id, contract) do
    {:ok, task} = Tasks.create_task(%{"workspace_id" => workspace_id, "title" => "Contract task"})
    {:ok, task} = Tasks.update_task(task, %{"meta" => %{"contract" => contract}})
    task
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
          "verify" => "mix test test/dran/contracts_test.exs"
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
