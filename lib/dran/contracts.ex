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

  Since the plans/steps model (wave A) the same machinery also operates on
  `%Dran.Step{}` (contract in `step.meta["contract"]`, `depends_on` edges
  step→step) — dual with the task API until F3. Run-scoped sequencing over
  steps lives in `Dran.Executions`; step readiness here is definitional
  (steps have no board status).
  """

  alias Dran.{Relation, Repo, Step}
  import Ecto.Query

  @verbs ~w(READ EDIT CREATE RUN VERIFY ASK)
  @statuses ~w(draft active superseded)

  # ──────────────────────────────────────────────────────────────────────────
  # Gate
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  True when the step carries a structurally valid contract (`meta.contract`
  that passes `lint/1` with an intent). A step without a contract is a
  regular step — this is the "is it a contract?" predicate.
  """
  def contract?(%Step{meta: %{"contract" => %{"intent" => intent}}} = step)
      when is_binary(intent) and intent != "" do
    match?({:ok, _}, lint(step))
  end

  def contract?(_), do: false

  @doc """
  Validate the structure of `task.meta.contract`. Returns `{:ok, warnings}`
  or `{:error, errors}`.

  Structural (machine-checkable) rules — the closed verb vocabulary, the
  verification funnel (a graph must reach a VERIFY before END), claim/gate
  shape, and required fields.
  """
  def lint(%Step{} = step) do
    case step.meta do
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
  def add_dependency(%Step{} = step, %Step{} = prerequisite) do
    with :ok <- same_workspace?(step, prerequisite),
         :ok <- reject_cycle(step, prerequisite) do
      %Relation{}
      |> Relation.changeset(%{
        source_id: step.id,
        source_type: "step",
        target_id: prerequisite.id,
        target_type: "step",
        relation_type: "depends_on"
      })
      |> Repo.insert(on_conflict: :nothing)
    end
  end

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

  defp same_workspace?(%{workspace_id: wid}, %{workspace_id: wid2})
       when wid == wid2 and not is_nil(wid),
       do: :ok

  defp same_workspace?(_, _), do: {:error, :invalid}

  defp reject_cycle(%{id: id}, %{id: id2}) when id == id2, do: {:error, :cycle}

  defp reject_cycle(step_or_task, prerequisite) do
    # Adding step→prerequisite creates a cycle if prerequisite transitively
    # depends on step.
    if step_or_task.id in transitive_prereqs(prerequisite) do
      {:error, :cycle}
    else
      :ok
    end
  end

  @doc """
  All step ids that are prerequisites (direct or transitive) of `step`.
  `depends_on` edges only; BFS from the step's direct prerequisites.
  """
  def transitive_prereqs(%Step{} = step) do
    do_transitive_steps(step_prerequisite_ids(step), MapSet.new())
  end

  # BFS with a queue of nodes to expand and a `seen` set of nodes that have
  # ALREADY been expanded. A node can be enqueued multiple times; it is
  # expanded only once. Handles diamond shapes (two tasks sharing a prereq)
  # without infinite loops.
  defp do_transitive_steps([], seen), do: MapSet.to_list(seen)

  defp do_transitive_steps(queue, seen) do
    {id, rest} = {hd(queue), tl(queue)}

    cond do
      MapSet.member?(seen, id) ->
        do_transitive_steps(rest, seen)

      true ->
        nexts = step_prerequisite_ids_by_ids([id])

        new =
          Enum.reject(nexts, fn n ->
            MapSet.member?(seen, n) or n == id
          end)

        do_transitive_steps(rest ++ new, MapSet.put(seen, id))
    end
  end

  @doc "Direct prerequisite step ids of a step (its `depends_on` targets)."
  def prerequisite_ids(%Step{id: id}) do
    Repo.all(
      from r in Relation,
        where:
          r.source_id == ^id and r.source_type == "step" and
            r.relation_type == "depends_on" and r.target_type == "step",
        select: r.target_id
    )
  end

  defp step_prerequisite_ids(%Step{} = step), do: prerequisite_ids(step)

  defp step_prerequisite_ids_by_ids(ids) when is_list(ids) and ids != [] do
    Repo.all(
      from r in Relation,
        where:
          r.source_id in ^ids and r.source_type == "step" and
            r.relation_type == "depends_on" and r.target_type == "step",
        select: r.target_id
    )
  end

  @doc """
  Step analogue of `dependency_edges/1`: depends_on edges among the given
  step ids (step→step), `[{source_id, target_id}]`. Same both-endpoints
  rule: an edge pointing outside the set is not part of this plan's DAG
  and is excluded. For readiness semantics see `dependency_states/2`.
  """
  def dependency_edges(step_ids, :step) when is_list(step_ids) and step_ids != [] do
    Repo.all(
      from r in Relation,
        where:
          r.source_id in ^step_ids and r.source_type == "step" and
            r.relation_type == "depends_on" and r.target_type == "step" and
            r.target_id in ^step_ids,
        select: {r.source_id, r.target_id}
    )
  end

  def dependency_edges(_, :step), do: []

  @doc """
  Step analogue of `dependency_states/1`: batch readiness for a set of
  step ids, `%{step_id => %{ready: boolean, blocked_count: non_neg_integer}}`.
  Two queries total (edges + terminal states of prerequisites).

  ⚠️ Steps have NO board status (definition nodes): a step prereq can only
  be open (never "done") at the definition layer, so only a step with zero
  direct prerequisites is ready here. Where prereq runs (attempts) matter,
  that is session-scoped readiness — `Dran.Executions.run_ready?/1` (wave B).
  Like its task twin, this query does NOT filter prereqs to the given set
  (external prereqs DO block readiness) — deliberately different from
  `dependency_edges/2`.
  """
  def dependency_states(step_ids, :step) when is_list(step_ids) and step_ids != [] do
    edges =
      Repo.all(
        from r in Relation,
          where:
            r.source_id in ^step_ids and r.source_type == "step" and
              r.relation_type == "depends_on" and r.target_type == "step",
          select: {r.source_id, r.target_id}
      )

    by_source = Enum.group_by(edges, &elem(&1, 0), &elem(&1, 1))

    Map.new(step_ids, fn id ->
      targets = Map.get(by_source, id, [])
      # Steps cannot be terminal at the definition layer (no board status),
      # so every direct prereq blocks: blocked_count = number of edges.
      blocked = length(targets)
      {id, %{ready: blocked == 0, blocked_count: blocked}}
    end)
  end

  def dependency_states(_, :step), do: %{}

  @doc """
  Is the step ready at the definition layer? Steps have no board status,
  so there is no terminal state a prerequisite could reach here — only a
  step without prerequisites is ready. Attempt-based readiness ("all
  prereq runs passed in this session") is `Dran.Executions.run_ready?/1`.
  """
  def ready?(%Step{} = step) do
    step_prerequisite_ids(step) == []
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Rendering
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Compute topological levels for a set of tasks over their `depends_on`
  edges. Returns a list of lists (level 0 = no prerequisites = leftmost
  column) keyed by task id.

  Cycle-safe: in the pathological case of a cycle it still terminates by
  not depending on a topological order being acyclic.

  Accepts `%Dran.Step{}` structs as well as tasks — steps are ordered by
  their step→step `depends_on` edges (plan DAG).
  """
  def levels(tasks) do
    ids = Enum.map(tasks, & &1.id)
    id_set = MapSet.new(ids)

    edges =
      for t <- tasks,
          id = t.id,
          prereq <- step_prerequisite_ids(t),
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
  # Rendering
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Render `step.meta.contract` as a riel-brief packet (9 sections). This is
  the interchange format a pulling agent reads.
  """
  def render_brief(%Step{} = step) do
    case step.meta do
      %{"contract" => %{"intent" => intent} = contract} when is_binary(intent) ->
        sections = [
          "# Task: #{step.title}",
          "",
          "## Objective",
          "We need #{intent}",
          "",
          brief_claims(step, contract),
          "",
          brief_gates(contract),
          "",
          brief_graph(contract),
          "",
          "## Context",
          "Pulled from #{step.workspace_id} — see step #{step.id} (workflow #{step.workflow_id}).",
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
          "Report the run outcome via the executions API; report ✓NN checkpoints to memory (source: step:<id>).",
          "",
          "## DO NOT",
          "Do not edit other steps, workflows, tasks or pages. Do not rewrite the brief. Do not invent context outside the snapshot."
        ]

        {:ok, Enum.join(List.flatten(sections), "\n")}

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
  # Freshness (fingerprint + stale detection)
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Content fingerprint of the inputs a step contract was generated from:
  step.id + contract + the step's `depends_on` edges (workflow topology).
  Stored on the contract at generation time.
  """
  def fingerprint(%Step{} = step), do: do_fingerprint(step_fingerprint_input(step))

  defp do_fingerprint(input) do
    :crypto.hash(:sha256, input)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp step_fingerprint_input(%Step{} = step) do
    edges =
      step
      |> step_prerequisite_ids()
      |> Enum.sort()
      |> Enum.join(",")

    contract =
      case step.meta do
        %{"contract" => contract} when is_map(contract) -> inspect(contract)
        _ -> ""
      end

    "#{step.id}|#{step.title}|#{step.body}|#{contract}|#{edges}"
  end
end
