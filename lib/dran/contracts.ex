defmodule Dran.Contracts do
  @moduledoc """
  Contracts — the executable brief attached to a task.

  A task becomes a contract when its `meta.contract` passes the structural
  linter (`contract?/1`). The contract is a versioned JSON document inside
  the task; `task.body` holds the rendered brief (the interchange format a
  pulling agent reads). See `.spike/workflows-design.md` for the full spec.

  Shape of `meta.contract`:

      %{
        version: 2,
        status: "draft" | "active" | "superseded",
        intent: "…",
        claims: [%{id: "P1", claim: "…", verify: "…"}],
        gates: [%{name: "…", cmd: "…", expect: "…", on_failure: "…"}],
        graph: %{nodes: [%{id: "S1", verb: "READ", label: "…"}],
                 edges: [%{from: "S1", to: "G1", guard: "yes"}]},
        context_snapshot: [%{type: "page|goal|task|memory", id: "…", why: "…", extract: "…"}],
        fingerprint: "sha…",
        model: "…", generated_by: "…",
        history: [%{version: 1, status: "superseded", …}]
      }

  The `graph` is stored as structured JSON (source of truth); mermaid and
  the SVG DAG view are renders from it.
  """

  alias Dran.{Relation, Repo, Task}
  import Ecto.Query

  @verbs ~w(READ EDIT CREATE RUN VERIFY ASK)
  @statuses ~w(draft active superseded)

  # ──────────────────────────────────────────────────────────────────────────
  # Gate
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  True when the task carries a structurally valid contract (`meta.contract`
  that passes `lint/1` with an intent). A task without a contract is a
  regular task — this is the "is it a contract?" predicate.
  """
  def contract?(%Task{meta: %{"contract" => %{"intent" => intent}}} = task)
      when is_binary(intent) and intent != "" do
    match?({:ok, _}, lint(task))
  end

  def contract?(_), do: false

  @doc """
  Validate the structure of `task.meta.contract`. Returns `{:ok, warnings}`
  or `{:error, errors}`.

  Structural (machine-checkable) rules — the closed verb vocabulary, the
  verification funnel (a graph must reach a VERIFY before END), claim/gate
  shape, and required fields.
  """
  def lint(%Task{} = task) do
    case task.meta do
      %{"contract" => contract} when is_map(contract) -> lint_contract(contract)
      _ -> {:error, [:no_contract]}
    end
  end

  def lint_contract(contract) do
    errors =
      []
      |> check_required(contract)
      |> check_claims(contract)
      |> check_gates(contract)
      |> check_graph(contract)

    if errors == [], do: {:ok, []}, else: {:error, errors}
  end

  defp check_required(errors, contract) do
    cond do
      not is_binary(contract["intent"]) or contract["intent"] == "" ->
        [:intent | errors]

      contract["status"] not in @statuses ->
        [:status | errors]

      true ->
        errors
    end
  end

  defp check_claims(errors, %{"claims" => claims}) when is_list(claims) do
    if Enum.all?(claims, &valid_claim?/1) do
      errors
    else
      [:claims | errors]
    end
  end

  defp check_claims(errors, _), do: [:claims | errors]

  defp valid_claim?(%{"id" => id, "claim" => claim, "verify" => verify})
       when is_binary(id) and id != "" and is_binary(claim) and claim != "" and
              is_binary(verify) and verify != "" do
    true
  end

  defp valid_claim?(_), do: false

  defp check_gates(errors, %{"gates" => gates}) when is_list(gates) do
    if Enum.all?(gates, &valid_gate?/1) do
      errors
    else
      [:gates | errors]
    end
  end

  defp check_gates(errors, _), do: [:gates | errors]

  defp valid_gate?(%{"name" => name, "cmd" => cmd, "expect" => expect})
       when is_binary(name) and name != "" and is_binary(cmd) and cmd != "" and
              is_binary(expect) and expect != "" do
    true
  end

  defp valid_gate?(_), do: false

  defp check_graph(errors, %{"graph" => %{"nodes" => nodes, "edges" => edges}})
       when is_list(nodes) and is_list(edges) do
    cond do
      nodes == [] ->
        [:graph_nodes | errors]

      Enum.any?(nodes, &(not valid_node?(&1))) ->
        [:graph_verbs | errors]

      not funnel_ok?(nodes, edges) ->
        [:graph_funnel | errors]

      true ->
        errors
    end
  end

  defp check_graph(errors, _), do: [:graph | errors]

  defp valid_node?(%{"id" => id, "verb" => verb}) when is_binary(id) and id != "" do
    verb in @verbs
  end

  defp valid_node?(_), do: false

  # The graph must reach a VERIFY node before the end — the verification
  # funnel. Cheap structural check: at least one VERIFY node exists and is
  # reachable from a start node.
  defp funnel_ok?(nodes, edges) do
    verify_ids = for %{"id" => id, "verb" => "VERIFY"} <- nodes, do: id
    start_ids = for %{"id" => id} <- nodes, not Enum.any?(edges, &(&1["to"] == id)), do: id
    reachable = reachable_from(start_ids, edges)
    verify_ids != [] and Enum.any?(verify_ids, &(&1 in reachable))
  end

  defp reachable_from(ids, edges) do
    by_from = Enum.group_by(edges, & &1["from"], & &1["to"])

    do_reach(ids, by_from, MapSet.new(ids))
  end

  defp do_reach([], _by_from, seen), do: MapSet.to_list(seen)

  defp do_reach([id | rest], by_from, seen) do
    nexts = Map.get(by_from, id, [])

    new =
      Enum.reject(nexts, fn n ->
        MapSet.member?(seen, n) or n == id
      end)

    do_reach(new ++ rest, by_from, MapSet.union(seen, MapSet.new(new)))
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Dependency edges (task→task via `depends_on`)
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Create a `depends_on` edge (task → prerequisite task) with a cycle guard.

  Returns `{:ok, relation}` or `{:error, :cycle | :not_found | :invalid}`.
  A self-dependency is rejected. Both tasks must belong to the same
  workspace.
  """
  def add_dependency(task, prerequisite) do
    with :ok <- same_workspace?(task, prerequisite),
         :ok <- reject_cycle(task, prerequisite) do
      %Relation{}
      |> Relation.changeset(%{
        source_id: task.id,
        source_type: "task",
        target_id: prerequisite.id,
        target_type: "task",
        relation_type: "depends_on"
      })
      |> Repo.insert(on_conflict: :nothing)
    end
  end

  defp same_workspace?(%Task{workspace_id: wid}, %Task{workspace_id: wid2})
       when wid == wid2 and not is_nil(wid),
       do: :ok

  defp same_workspace?(_, _), do: {:error, :invalid}

  defp reject_cycle(%Task{id: id}, %Task{id: id2}) when id == id2, do: {:error, :cycle}

  defp reject_cycle(task, prerequisite) do
    # Adding task→prerequisite creates a cycle if prerequisite transitively
    # depends on task.
    if task.id in transitive_prereqs(prerequisite) do
      {:error, :cycle}
    else
      :ok
    end
  end

  @doc """
  All task ids that are prerequisites (direct or transitive) of `task`.
  `depends_on` edges only; DFS from the task's direct prerequisites.
  """
  def transitive_prereqs(%Task{} = task) do
    do_transitive(prerequisite_ids(task), MapSet.new())
  end

  # BFS with a queue of nodes to expand and a `seen` set of nodes that have
  # ALREADY been expanded. A node can be enqueued multiple times; it is
  # expanded only once. Handles diamond shapes (two tasks sharing a prereq)
  # without infinite loops.
  defp do_transitive([], seen), do: MapSet.to_list(seen)

  defp do_transitive(queue, seen) do
    {id, rest} = {hd(queue), tl(queue)}

    cond do
      MapSet.member?(seen, id) ->
        do_transitive(rest, seen)

      true ->
        nexts = prerequisite_ids_by_ids([id])

        new =
          Enum.reject(nexts, fn n ->
            MapSet.member?(seen, n) or n == id
          end)

        do_transitive(rest ++ new, MapSet.put(seen, id))
    end
  end

  @doc "Direct prerequisite task ids of a task (its `depends_on` targets)."
  def prerequisite_ids(%Task{id: id}) do
    Repo.all(
      from r in Relation,
        where:
          r.source_id == ^id and r.source_type == "task" and
            r.relation_type == "depends_on" and r.target_type == "task",
        select: r.target_id
    )
  end

  defp prerequisite_ids_by_ids(ids) when is_list(ids) and ids != [] do
    Repo.all(
      from r in Relation,
        where:
          r.source_id in ^ids and r.source_type == "task" and
            r.relation_type == "depends_on" and r.target_type == "task",
        select: r.target_id
    )
  end

  @doc """
  depends_on edges among the given task ids: `[{source_id, target_id}]`.
  Backs the workflow graph view.
  """
  def dependency_edges(task_ids) when is_list(task_ids) and task_ids != [] do
    Repo.all(
      from r in Relation,
        where:
          r.source_id in ^task_ids and r.source_type == "task" and
            r.relation_type == "depends_on" and r.target_type == "task",
        select: {r.source_id, r.target_id}
    )
  end

  def dependency_edges(_), do: []

  @doc """
  Batch dependency state for a set of task ids:
  `%{task_id => %{ready: boolean, blocked_count: non_neg_integer}}`.

  Two queries total (edges + statuses of prerequisites) instead of two per
  task — backs the workflows index and show views.
  """
  def dependency_states(task_ids) when is_list(task_ids) and task_ids != [] do
    edges = dependency_edges(task_ids)

    prereq_ids = edges |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    done_ids =
      if prereq_ids == [] do
        MapSet.new()
      else
        Repo.all(
          from t in Task,
            where: t.id in ^prereq_ids and t.status in ^~w(done cancelled),
            select: t.id
        )
        |> MapSet.new()
      end

    by_source = Enum.group_by(edges, &elem(&1, 0), &elem(&1, 1))

    Map.new(task_ids, fn id ->
      targets = Map.get(by_source, id, [])
      blocked = Enum.count(targets, &(&1 not in done_ids))
      {id, %{ready: blocked == 0, blocked_count: blocked}}
    end)
  end

  def dependency_states(_), do: %{}

  @doc """
  Is the task ready to execute? True when all its direct prerequisites are
  in a terminal state (`done` or `cancelled`).
  """
  def ready?(%Task{} = task) do
    ids = prerequisite_ids(task)
    ready_ids?(ids)
  end

  defp ready_ids?([]), do: true

  defp ready_ids?(ids) do
    done =
      Repo.exists?(
        from t in Task,
          where: t.id in ^ids and t.status in ^~w(done cancelled)
      )

    # ready only when ALL prerequisites are done/cancelled — a single
    # pending dep blocks it.
    done and
      not Repo.exists?(
        from t in Task,
          where: t.id in ^ids and t.status not in ^~w(done cancelled)
      )
  end

  @doc "Ids of direct prerequisites that are NOT in a terminal state (blocking this task)."
  def blocking_prereqs(%Task{} = task) do
    ids = prerequisite_ids(task)

    if ids == [] do
      []
    else
      Repo.all(
        from t in Task,
          where: t.id in ^ids and t.status not in ^~w(done cancelled),
          select: t.id
      )
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Rendering
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Render `task.meta.contract` as a riel-brief packet (9 sections). This is
  the interchange format a pulling agent reads; it also feeds `task.body`.
  """
  def render_brief(%Task{} = task) do
    case task.meta do
      %{"contract" => %{"intent" => intent} = contract} when is_binary(intent) ->
        sections = [
          "# Task: #{task.title}",
          "",
          "## Objective",
          "We need #{intent}",
          "",
          brief_claims(task, contract),
          "",
          brief_gates(contract),
          "",
          brief_graph(contract),
          "",
          "## Context",
          "Pulled from #{task.workspace_id} — see task #{task.id}.",
          "",
          "## Constraints",
          "Follow the closed verb vocabulary and the verification funnel (riel-contract).",
          "",
          "## Pre-registered claims",
          "The P-ids above are declared before execution; a failed claim is refuted, never reinterpreted.",
          "",
          "## Execution graph",
          "The mermaid above is the execution plan; follow it textually.",
          "",
          "## Deliverable",
          "Move the task status to done when all gates pass; report ✓NN checkpoints to memory (source: task:<id>).",
          "",
          "## DO NOT",
          "Do not edit other tasks, goals or pages. Do not rewrite the brief. Do not invent context outside the snapshot."
        ]

        {:ok, Enum.join(sections, "\n")}

      _ ->
        {:error, :no_contract}
    end
  end

  defp brief_claims(_task, contract) do
    claims =
      case contract["claims"] do
        list when is_list(list) -> list
        _ -> []
      end

    lines =
      for %{"id" => id, "claim" => claim, "verify" => verify} <- claims do
        "- **#{id}** — #{claim} — verify with: #{verify}"
      end

    ["## Claims"] ++ lines
  end

  defp brief_gates(contract) do
    gates =
      case contract["gates"] do
        list when is_list(list) -> list
        _ -> []
      end

    lines =
      for gate <- gates do
        "- **#{gate["name"]}** — `#{gate["cmd"]}` — expected: #{gate["expect"]}" <>
          if(gate["on_failure"], do: " — on failure: #{gate["on_failure"]}", else: "")
      end

    ["## Verification gates"] ++ lines
  end

  defp brief_graph(contract) do
    case contract["graph"] do
      %{"nodes" => nodes, "edges" => edges} ->
        graph_lines =
          ["## Execution graph (mermaid)", "", "```mermaid", "flowchart TD"] ++
            for %{"id" => id, "verb" => verb, "label" => label} <- nodes do
              label = label || id
              "  #{id}[\"#{verb} #{label}\"]"
            end ++
            for %{"from" => from, "to" => to, "guard" => guard} <- edges do
              edge = if guard, do: " -->|#{guard}| ", else: " --> "
              "  #{from}#{edge}#{to}"
            end ++
            ["```"]

        graph_lines

      _ ->
        ["## Execution graph", "No graph defined."]
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # DAG layout (server-side topological levels → columns)
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Compute topological levels for a set of tasks over their `depends_on`
  edges. Returns a list of lists (level 0 = no prerequisites = leftmost
  column) keyed by task id.

  Cycle-safe: in the pathological case of a cycle it still terminates by
  not depending on a topological order being acyclic.
  """
  def levels(tasks) do
    ids = Enum.map(tasks, & &1.id)
    id_set = MapSet.new(ids)

    edges =
      for %Task{id: id} = t <- tasks,
          prereq <- prerequisite_ids(t),
          MapSet.member?(id_set, prereq) do
        {prereq, id}
      end

    in_degree = Map.new(ids, &{&1, 0})

    in_degree =
      Enum.reduce(edges, in_degree, fn {_from, to}, acc ->
        Map.update!(acc, to, &(&1 + 1))
      end)

    by_level =
      Enum.reduce_while(Stream.iterate(0, &(&1 + 1)), {ids, in_degree, []}, fn _level,
                                                                               {remaining, deg,
                                                                                acc} ->
        zero = Enum.filter(remaining, &(Map.get(deg, &1, 0) == 0))

        if zero == [] do
          # cycle guard: emit whatever is left rather than loop forever
          {:halt, Enum.reverse([remaining | acc])}
        else
          new_remaining = remaining -- zero

          deg =
            Enum.reduce(zero, deg, fn id, d ->
              Enum.reduce(edges, d, fn {from, to}, acc2 ->
                if from == id, do: Map.update!(acc2, to, &(&1 - 1)), else: acc2
              end)
            end)

          if new_remaining == [] do
            {:halt, Enum.reverse([zero | acc])}
          else
            {:cont, {new_remaining, deg, [zero | acc]}}
          end
        end
      end)

    by_level
  end

  @doc false
  def verbs, do: @verbs

  # ──────────────────────────────────────────────────────────────────────────
  # Freshness (fingerprint + stale detection)
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Content fingerprint of the inputs a contract was generated from: task
  title + body + goal context. Stored on the contract at generation time;
  `stale?/1` recomputes and compares.
  """
  def fingerprint(%Task{} = task, goal \\ nil) do
    :crypto.hash(:sha256, fingerprint_input(task, goal))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp fingerprint_input(%Task{} = task, goal) do
    goal_part =
      case goal do
        %Dran.Goal{} = g -> "#{g.id}:#{g.title}:#{g.updated_at}"
        _ -> "no-goal"
      end

    "#{task.id}|#{task.title}|#{task.body}|#{goal_part}"
  end

  @doc """
  Is the contract stale? True when the stored fingerprint differs from the
  current one (task title/body or linked goal changed after generation).
  Contracts without a stored fingerprint are never stale (hand-written).
  """
  def stale?(%Task{} = task) do
    case task.meta do
      %{"contract" => %{"fingerprint" => stored}} when is_binary(stored) and stored != "" ->
        stored != fingerprint(task, linked_goal(task))

      _ ->
        false
    end
  end

  defp linked_goal(%Task{id: id, workspace_id: workspace_id}) do
    import Ecto.Query

    Repo.one(
      from g in Dran.Goal,
        join: r in Relation,
        on:
          r.target_id == g.id and r.target_type == "goal" and
            r.relation_type == "part_of" and r.source_id == ^id and
            r.source_type == "task",
        where: g.workspace_id == ^workspace_id,
        limit: 1
    )
  end
end
