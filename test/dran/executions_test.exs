defmodule Dran.ExecutionsTest do
  @moduledoc """
  Executions sobre workflows (post-pivot 2026-09): open_session(workflow)
  con snapshot congelado, runs upfront por step, run_ready? por sesión
  (topología congelada), start_run/close_run/runREADY sin spawn (el run
  es el único runtime), update_progress por fase, retry superseded,
  abort_session.

  Port de los casos wave B re-keyed al modelo workflows: toda la
  superficie spawn/cierre-dual/reconcile/archivo muere con el pivot
  (P7 del plan). Concurrency guarantees preserved: conditional claims,
  transactional close, retry superseded.
  """

  use Dran.DataCase, async: true

  import Ecto.Query

  alias Dran.{
    Contracts,
    Executions,
    Goals,
    Knowledge,
    Relation,
    Repo,
    Run,
    WorkflowSession,
    Workflows
  }

  setup do
    {:ok, ws} =
      Dran.Knowledge.create_workspace(%{
        name: "Executions WS #{System.unique_integer([:positive])}",
        slug: "exec-ws-#{System.unique_integer([:positive])}"
      })

    {:ok, ws: ws}
  end

  # ──────────────────────────────────────────────────────────────────────────
  # P1 — open_session(workflow): runs upfront + snapshot congelado
  # ──────────────────────────────────────────────────────────────────────────

  test "P1: open_session(workflow) creates pending runs upfront for every step", %{
    ws: ws
  } do
    {workflow, steps} = new_workflow(ws, ["Step 1", "Step 2"])

    {:ok, session} = Executions.open_session(workflow, label: "release 1")

    session = Repo.preload(session, :runs)
    assert session.status == "in_flight"
    assert session.label == "release 1"
    assert session.workflow_id == workflow.id
    # goal_id denormalizado desde el link opcional del workflow.
    assert session.goal_id == nil

    run_step_ids = Enum.map(session.runs, & &1.step_id) |> MapSet.new()
    assert run_step_ids == MapSet.new(Enum.map(steps, & &1.id))
    assert Enum.all?(session.runs, &(&1.status == "pending"))
    assert Enum.all?(session.runs, &(&1.attempt == 1))
    # Sin contrato en los steps → nil.
    assert Enum.all?(session.runs, &(&1.contract_version == nil))
    # El run es el runtime: nada de tasks.
    assert Repo.aggregate(from(t in Dran.Task), :count) == 0
  end

  test "P1: open_session freezes the snapshot with steps and depends_on edges", %{ws: ws} do
    {workflow, [a, b, c]} = new_workflow(ws, ["A", "B", "C"])

    {:ok, _} = Contracts.add_dependency(b, a)
    {:ok, _} = Contracts.add_dependency(c, b)

    {:ok, session} = Executions.open_session(workflow)

    snapshot = session.snapshot

    assert snapshot["edges"] |> Enum.map(&List.to_tuple/1) |> MapSet.new() ==
             MapSet.new([{b.id, a.id}, {c.id, b.id}])

    assert snapshot["steps"] |> length() == 3

    assert Enum.map(snapshot["steps"], & &1["id"]) |> MapSet.new() ==
             MapSet.new([a.id, b.id, c.id])

    assert Enum.all?(snapshot["steps"], &is_binary(&1["title"]))
  end

  test "P1: snapshot and contract_version stay frozen when the workflow is edited after open",
       %{ws: ws} do
    contract = %{
      "intent" => "Ship the login flow",
      "claims" => [%{"id" => "P1", "claim" => "form validates", "verify" => "mix test"}],
      "gates" => [%{"name" => "test", "cmd" => "mix test", "expect" => "exit 0"}]
    }

    {workflow, [step1]} =
      new_workflow(ws, [%{title: "Contracted step", contract: contract}])

    {:ok, session} = Executions.open_session(workflow)
    session = Repo.preload(session, :runs)
    [run] = session.runs
    frozen = run.contract_version
    assert frozen["intent"] == "Ship the login flow"
    assert frozen["claims"] == contract["claims"]

    assert session.snapshot["steps"] == [
             %{"id" => step1.id, "title" => "Contracted step", "contract" => frozen}
           ]

    # El workflow muta DESPUÉS de abrir: título del step, contrato del step
    # y un step nuevo — el snapshot de la sesión queda intacto.
    {:ok, _} = Workflows.update_step(step1, %{"title" => "Renamed"})

    {:ok, _} =
      Workflows.update_step(step1, contract_attrs(Map.put(contract, "intent", "Changed")))

    {:ok, _} = Workflows.create_step(workflow, %{"title" => "Late", "slug" => "late-step"})

    session = Repo.reload!(session)

    assert session.snapshot["steps"] == [
             %{"id" => step1.id, "title" => "Contracted step", "contract" => frozen}
           ]

    # El run conserva el contract_version congelado.
    assert Repo.get!(Run, run.id).contract_version == frozen
  end

  test "P1: open_session refuses a workflow without steps and an archived workflow", %{ws: ws} do
    {:ok, empty} =
      Workflows.create_workflow(%{
        workspace_id: ws.id,
        title: "Empty",
        slug: "empty-#{System.unique_integer([:positive])}"
      })

    assert {:error, :workflow_has_no_steps} = Executions.open_session(empty)

    {workflow, [_step]} = new_workflow(ws, ["S"])

    {:ok, archived} =
      Workflows.update_workflow(workflow, %{"status" => "archived"})

    assert {:error, :workflow_archived} = Executions.open_session(archived)
  end

  test "P1: one_shot refuses a second pass after the first session exists (review #7)", %{
    ws: ws
  } do
    {workflow, [_step]} = new_workflow(ws, ["S"])

    {:ok, workflow} =
      Workflows.update_workflow(workflow, %{"kind" => "one_shot"})

    assert {:ok, _session} = Executions.open_session(workflow)
    assert {:error, :workflow_already_ran} = Executions.open_session(workflow)
  end

  test "P1: open_session with actor_id records the driver; label and context are stored", %{
    ws: ws
  } do
    {workflow, _steps} = new_workflow(ws, ["Step"])

    {:ok, actor} =
      Dran.Actors.create_actor(%{
        "name" => "exec-agent-#{System.unique_integer([:positive])}",
        "kind" => "agent"
      })

    {:ok, session} =
      Executions.open_session(workflow,
        label: "lead Acme",
        context: %{"client" => "Acme"},
        actor_id: actor.id
      )

    session = Repo.preload(session, :runs)
    assert session.actor_id == actor.id
    assert session.label == "lead Acme"
    assert session.context == %{"client" => "Acme"}
    assert Enum.all?(session.runs, &(&1.actor_id == actor.id))
  end

  test "P1: the workflow's optional goal link is denormalized into the session", %{ws: ws} do
    {:ok, goal} =
      Goals.create_goal(%{
        "workspace_id" => ws.id,
        "title" => "G #{System.unique_integer([:positive])}",
        "slug" => "g-#{System.unique_integer([:positive])}"
      })

    {:ok, workflow} =
      Workflows.create_workflow(%{
        workspace_id: ws.id,
        title: "W",
        slug: "w-#{System.unique_integer([:positive])}",
        goal_id: goal.id
      })

    {:ok, _} = Workflows.create_step(workflow, %{"title" => "S", "slug" => "s"})

    {:ok, session} = Executions.open_session(workflow)
    assert session.goal_id == goal.id
  end

  # ──────────────────────────────────────────────────────────────────────────
  # P6 — run_ready? exige prereqs passed EN ESA sesión (ALL)
  # ──────────────────────────────────────────────────────────────────────────

  test "P6: run_ready? requires prerequisites passed in the same session", %{ws: ws} do
    {workflow, [prereq_step, step]} = new_workflow(ws, ["Prereq", "Step"])
    {:ok, _} = Contracts.add_dependency(step, prereq_step)

    {:ok, s1} = Executions.open_session(workflow)
    {:ok, s2} = Executions.open_session(workflow)

    [step_run_s1, prereq_run_s1] = runs_by_step(s1, [step.id, prereq_step.id])
    [step_run_s2, prereq_run_s2] = runs_by_step(s2, [step.id, prereq_step.id])

    # Sin prereq pasado: el paso no está listo en ninguna sesión.
    refute Executions.run_ready?(step_run_s1)
    refute Executions.run_ready?(step_run_s2)

    # s1 cierra el prereq como passed; el paso sigue bloqueado en s2.
    {:ok, prereq_run_s1} = Executions.start_run(prereq_run_s1)
    {:ok, _} = Executions.close_run(prereq_run_s1, status: "passed", outcome: "ok")

    assert Executions.run_ready?(step_run_s1)
    refute Executions.run_ready?(step_run_s2)

    # s2 cierra su propio prereq; ahora el paso de s2 está listo.
    {:ok, prereq_run_s2} = Executions.start_run(prereq_run_s2)
    {:ok, _} = Executions.close_run(prereq_run_s2, status: "passed", outcome: "ok")

    assert Executions.run_ready?(step_run_s2)
  end

  test "P6: run_ready? requires ALL prerequisites passed — one of two is not enough", %{ws: ws} do
    {workflow, [pa, pb, final]} = new_workflow(ws, ["Prereq A", "Prereq B", "Final step"])

    {:ok, _} = Contracts.add_dependency(final, pa)
    {:ok, _} = Contracts.add_dependency(final, pb)

    {:ok, session} = Executions.open_session(workflow)
    [run_pa, run_pb, run_final] = runs_by_step(session, [pa.id, pb.id, final.id])

    refute Executions.run_ready?(run_final)

    # Solo A passed → final sigue bloqueado.
    {:ok, run_pa} = Executions.start_run(run_pa)
    {:ok, _} = Executions.close_run(run_pa, status: "passed", outcome: "ok")
    refute Executions.run_ready?(run_final)

    # A y B passed → final listo.
    {:ok, run_pb} = Executions.start_run(run_pb)
    {:ok, _} = Executions.close_run(run_pb, status: "passed", outcome: "ok")
    assert Executions.run_ready?(run_final)
  end

  test "P6: cross-workflow edges never sequence a session", %{ws: ws} do
    {workflow_a, [step_a]} = new_workflow(ws, ["Step A"])
    {_workflow_b, [external]} = new_workflow(ws, ["External step"])

    # Edge cross-workflow creada ANTES de abrir: la sesión secuencía SOLO
    # los steps de su workflow (dependency_edges exige ambos extremos en el
    # conjunto). La edge es metadata de definición: no bloquea la pasada.
    {:ok, _} = Contracts.add_dependency(step_a, external)

    {:ok, session} = Executions.open_session(workflow_a)
    [run_step] = runs_by_step(session, [step_a.id])

    assert Executions.run_ready?(run_step)
  end

  test "P6: a cross-workflow edge added AFTER open does NOT re-sequence (frozen topology)",
       %{ws: ws} do
    {workflow_a, [step_a]} = new_workflow(ws, ["Step A"])
    {_workflow_b, [external]} = new_workflow(ws, ["External step"])

    {:ok, session} = Executions.open_session(workflow_a)
    [run_step] = runs_by_step(session, [step_a.id])

    assert Executions.run_ready?(run_step)

    # Una edge NUEVA en el workflow vivo no re-secuencia la sesión abierta:
    # run_ready? lee el snapshot congelado, no las relations live.
    {:ok, _} = Contracts.add_dependency(step_a, external)
    assert Executions.run_ready?(run_step)
  end

  test "P6: an in-workflow edge added mid-session does NOT re-sequence (frozen topology)",
       %{ws: ws} do
    {workflow, [first, second, third]} = new_workflow(ws, ["First", "Second", "Third"])

    {:ok, session} = Executions.open_session(workflow)
    [run_first, _run_second, run_third] = runs_by_step(session, [first.id, second.id, third.id])

    # Sin edges al abrir: todo ready.
    assert Executions.run_ready?(run_third)

    # Se agrega second→third al workflow VIVO a mitad de sesión: la sesión
    # abierta NO se re-secuencia (el snapshot no cambió).
    {:ok, _} = Contracts.add_dependency(third, second)
    assert Executions.run_ready?(run_third)

    # Pero una sesión NUEVA sobre el mismo workflow SÍ ve la edge nueva.
    {:ok, session2} = Executions.open_session(workflow)
    [run_third_s2] = runs_by_step(session2, [third.id])
    refute Executions.run_ready?(run_third_s2)
    assert Executions.run_ready?(run_first)
  end

  # ──────────────────────────────────────────────────────────────────────────
  # P4 — progreso por fase (overwrite) sin cerrar el run
  # ──────────────────────────────────────────────────────────────────────────

  test "P4: update_progress overwrites the phase map on an in_flight run without closing it",
       %{ws: ws} do
    {workflow, [step]} = new_workflow(ws, ["Step"])

    {:ok, session} = Executions.open_session(workflow)
    [run] = runs_by_step(session, [step.id])

    # Un run pending no reporta progreso.
    assert {:error, :not_in_flight} =
             Executions.update_progress(run.id, %{"phase" => "early"})

    {:ok, run} = Executions.start_run(run)

    {:ok, r1} =
      Executions.update_progress(run.id, %{
        "phase" => "implementing",
        "gates" => %{"compile" => "ok"}
      })

    assert r1.progress == %{"phase" => "implementing", "gates" => %{"compile" => "ok"}}
    assert r1.status == "in_flight"

    # Overwrite: la segunda actualización REEMPLAZA (decisión ?02).
    {:ok, r2} =
      Executions.update_progress(run.id, %{"phase" => "verifying", "gates" => %{}})

    assert r2.progress == %{"phase" => "verifying", "gates" => %{}}

    # El run sigue abierto: no cerró la sesión ni cambió status.
    assert Repo.get!(WorkflowSession, session.id).status == "in_flight"
    assert Repo.get!(Run, run.id).status == "in_flight"

    # Un run cerrado ya no acepta progreso.
    {:ok, _} = Executions.close_run(run, status: "passed", outcome: "ok")
    assert {:error, :not_in_flight} = Executions.update_progress(run.id, %{"phase" => "x"})
  end

  test "P4: update_progress on a missing run returns run_not_found", %{ws: ws} do
    assert {:error, :run_not_found} =
             Executions.update_progress(Ecto.UUID.generate(), %{"phase" => "x"})
  end

  # ──────────────────────────────────────────────────────────────────────────
  # P3 — start_run claim condicional (P7/claim ?07) + close sin writeback
  # ──────────────────────────────────────────────────────────────────────────

  test "start_run claims pending → in_flight; a stale struct loses; no task is ever spawned",
       %{ws: ws} do
    {workflow, [step]} = new_workflow(ws, ["Step"])

    {:ok, session} = Executions.open_session(workflow)
    [run] = runs_by_step(session, [step.id])

    {:ok, claimed} = Executions.start_run(run)
    assert claimed.status == "in_flight"

    # Dos agentes sosteniendo el MISMO struct pending: el update condicional
    # deja pasar a uno solo.
    assert {:error, {:wrong_status, "in_flight", "pending"}} = Executions.start_run(run)

    # El run es el runtime: NINGUNA task fue creada.
    assert Repo.aggregate(from(t in Dran.Task), :count) == 0
  end

  test "start_run with actor_id stamps the claimer", %{ws: ws} do
    {workflow, [step]} = new_workflow(ws, ["Step"])

    {:ok, actor} =
      Dran.Actors.create_actor(%{
        "name" => "claimer-#{System.unique_integer([:positive])}",
        "kind" => "agent"
      })

    {:ok, session} = Executions.open_session(workflow)
    [run] = runs_by_step(session, [step.id])

    {:ok, claimed} = Executions.start_run(run, actor_id: actor.id)
    assert claimed.actor_id == actor.id
  end

  test "start_run on a closed session is rejected", %{ws: ws} do
    {workflow, [step]} = new_workflow(ws, ["Step"])

    {:ok, session} = Executions.open_session(workflow)
    [run] = runs_by_step(session, [step.id])
    {:ok, run} = Executions.start_run(run)
    {:ok, _} = Executions.close_run(run, status: "passed", outcome: "ok")

    # La sesión auto-cerró passed. Una segunda sesión abortada deja un run
    # pending fantasma: un start tardío no puede arrancarlo.
    {:ok, session2} = Executions.open_session(workflow, label: "second pass")
    [run2] = runs_by_step(session2, [step.id])
    {:ok, _} = Executions.abort_session(session2)

    stale = %Run{run2 | status: "pending"}
    assert {:error, :session_closed} = Executions.start_run(stale)
  end

  # ──────────────────────────────────────────────────────────────────────────
  # P5 — close_run persiste outcome+gates; último run cierra sesión
  # ──────────────────────────────────────────────────────────────────────────

  # NOTE: the Ecto SQL sandbox serializes the two Tasks on one shared
  # connection, so this cannot actually reproduce the interleaving the
  # FOR UPDATE lock in maybe_close_session/1 defends against (two real
  # DB transactions each seeing the other's run open). It covers the
  # concurrent-call path end to end; the lock itself is verified by
  # construction (session row locked inside the close transaction).
  test "P5: concurrent closes of the last two runs both succeed and the session closes",
       %{ws: ws} do
    {workflow, [step1, step2]} = new_workflow(ws, ["S1", "S2"])

    {:ok, session} = Executions.open_session(workflow)
    [run1, run2] = runs_by_step(session, [step1.id, step2.id])
    {:ok, run1} = Executions.start_run(run1)
    {:ok, run2} = Executions.start_run(run2)

    # Two agents close the last two open runs CONCURRENTLY.
    parent = self()

    tasks =
      for run <- [run1, run2] do
        Task.async(fn ->
          result = Executions.close_run(run, status: "passed", outcome: "concurrent")
          send(parent, {:closed, result})
          result
        end)
      end

    results = Task.await_many(tasks, 5_000)
    assert Enum.all?(results, &match?({:ok, _}, &1))

    session = Repo.get!(WorkflowSession, session.id)
    assert session.status == "passed"
    assert session.finished_at != nil
  end

  test "P5: close_run persists outcome and gate_results; the last run closes the session",
       %{ws: ws} do
    gates = %{"G1" => %{"cmd" => "mix test", "exit" => 0}}

    {workflow, [step]} =
      new_workflow(ws, [%{title: "Step", contract: %{"intent" => "i"}}])

    {:ok, session} = Executions.open_session(workflow)
    [run] = runs_by_step(session, [step.id])

    {:ok, run} = Executions.start_run(run)

    {:ok, closed} =
      Executions.close_run(run, status: "passed", outcome: "shipped", gate_results: gates)

    assert closed.status == "passed"
    assert closed.outcome == "shipped"
    assert closed.gate_results == gates

    # Último run → sesión passed con finished_at. Sin writeback a goals.
    session = Repo.get!(WorkflowSession, session.id)
    assert session.status == "passed"
    assert session.finished_at != nil
    assert Repo.aggregate(from(t in Dran.Task), :count) == 0
  end

  test "P5: a skipped run still closes the session as passed", %{ws: ws} do
    {workflow, [do_step, skip_step]} = new_workflow(ws, ["Do", "Skip me"])

    {:ok, session} = Executions.open_session(workflow)
    [run_do, run_skip] = runs_by_step(session, [do_step.id, skip_step.id])

    {:ok, run_do} = Executions.start_run(run_do)
    {:ok, _} = Executions.close_run(run_do, status: "passed", outcome: "ok")

    {:ok, run_skip} = Executions.start_run(run_skip)
    {:ok, _} = Executions.close_run(run_skip, status: "skipped", outcome: "fuera de alcance")

    closed = Repo.get!(WorkflowSession, session.id)
    assert closed.status == "passed"
    assert closed.finished_at != nil
  end

  test "P5: a failed run closes the session as failed", %{ws: ws} do
    {workflow, [step]} = new_workflow(ws, ["Step"])

    {:ok, session} = Executions.open_session(workflow)
    [run] = runs_by_step(session, [step.id])

    {:ok, run} = Executions.start_run(run)
    {:ok, _} = Executions.close_run(run, status: "failed", outcome: "gate rojo")

    assert Repo.get!(WorkflowSession, session.id).status == "failed"
  end

  test "P5: close_run on a pending/stale run is rejected without side effects", %{ws: ws} do
    {workflow, [step]} = new_workflow(ws, ["Step"])

    {:ok, session} = Executions.open_session(workflow)
    [run] = runs_by_step(session, [step.id])

    # close_run sobre un run pending: {:error, :not_in_flight}, sin efectos.
    assert {:error, :not_in_flight} = Executions.close_run(run, status: "passed")
    assert Repo.get!(Run, run.id).status == "pending"
    assert Repo.get!(WorkflowSession, session.id).status == "in_flight"

    # Doble cierre con el MISMO struct in_flight: el segundo pierde.
    {:ok, run} = Executions.start_run(run)
    {:ok, _} = Executions.close_run(run, status: "passed", outcome: "first")

    stale = %Run{run | status: "in_flight"}

    assert {:error, :not_in_flight} =
             Executions.close_run(stale, status: "failed", outcome: "second")

    assert Repo.get!(Run, run.id).status == "passed"
  end

  test "invalid close status is rejected without side effects", %{ws: ws} do
    {workflow, [step]} = new_workflow(ws, ["Step"])

    {:ok, session} = Executions.open_session(workflow)
    [run] = runs_by_step(session, [step.id])
    {:ok, _} = Executions.start_run(run)

    assert {:error, :invalid_status} = Executions.close_run(run, status: "banana")
    assert Repo.get!(Run, run.id).status == "in_flight"
    assert Repo.get!(WorkflowSession, session.id).status == "in_flight"
  end

  # ───────────────────────────────────────────────────────── working ─────────
  # Retry semantics (superseded)
  # ──────────────────────────────────────────────────────────────────────────

  test "retry_run creates a new attempt for the same (session, step) and reopens a failed session",
       %{ws: ws} do
    {workflow, [step]} = new_workflow(ws, ["Step"])

    {:ok, session} = Executions.open_session(workflow)
    [run] = runs_by_step(session, [step.id])

    {:ok, run} = Executions.start_run(run)
    {:ok, failed_run} = Executions.close_run(run, status: "failed", outcome: "flaky")

    # Auto-cierre failed (un solo step).
    assert Repo.get!(WorkflowSession, session.id).status == "failed"

    # Retry legítimo: reabre la sesión y crea attempt 2.
    {:ok, retry} = Executions.retry_run(failed_run)
    assert retry.session_id == session.id
    assert retry.step_id == step.id
    assert retry.attempt == 2
    assert retry.status == "pending"
    # Ownership: el retry hereda el stamp — la nueva attempt sigue siendo
    # del dueño original, nunca un claim abierto para otro actor.
    assert retry.actor_id == run.actor_id
    assert Repo.get!(WorkflowSession, session.id).status == "in_flight"

    runs = Executions.list_runs(session)
    assert length(runs) == 2
    assert Enum.count(runs, &(&1.status == "failed")) == 1
    assert Enum.count(runs, &(&1.status == "pending")) == 1
  end

  test "retry of a superseded attempt is rejected and never corrupts a closed session", %{ws: ws} do
    {workflow, [step]} = new_workflow(ws, ["Step"])

    {:ok, session} = Executions.open_session(workflow)
    [run] = runs_by_step(session, [step.id])

    {:ok, run} = Executions.start_run(run)
    {:ok, failed_run} = Executions.close_run(run, status: "failed", outcome: "flaky")

    {:ok, retry} = Executions.retry_run(failed_run)
    {:ok, retry} = Executions.start_run(retry)
    {:ok, _} = Executions.close_run(retry, status: "passed", outcome: "ok")

    closed = Repo.get!(WorkflowSession, session.id)
    assert closed.status == "passed"
    assert closed.finished_at != nil

    # Un retry del attempt 1 VIEJO: rechazado SIN reabrir ni corromper.
    assert {:error, {:superseded, "passed"}} = Executions.retry_run(failed_run)
    still_closed = Repo.get!(WorkflowSession, session.id)
    assert still_closed.status == "passed"
    assert still_closed.finished_at == closed.finished_at
  end

  test "retry after a failed auto-close reopens the session", %{ws: ws} do
    {workflow, [step]} = new_workflow(ws, ["Step"])

    {:ok, session} = Executions.open_session(workflow)
    [run] = runs_by_step(session, [step.id])

    {:ok, run} = Executions.start_run(run)
    {:ok, run} = Executions.close_run(run, status: "failed", outcome: "gate rojo")

    assert Repo.get!(WorkflowSession, session.id).status == "failed"

    {:ok, retry} = Executions.retry_run(run)
    assert retry.status == "pending"
    assert Repo.get!(WorkflowSession, session.id).status == "in_flight"
    assert Repo.get!(WorkflowSession, session.id).finished_at == nil
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Concurrency guards (claims condicionales)
  # ──────────────────────────────────────────────────────────────────────────

  test "session_progress counts runs by status and retries count too", %{ws: ws} do
    {workflow, [step]} = new_workflow(ws, ["Step"])

    {:ok, session} = Executions.open_session(workflow)

    assert Executions.session_progress(session) == %{
             total: 1,
             pending: 1,
             in_flight: 0,
             passed: 0,
             failed: 0,
             skipped: 0
           }

    [run] = runs_by_step(session, [step.id])
    {:ok, run} = Executions.start_run(run)
    {:ok, run} = Executions.close_run(run, status: "failed", outcome: "nope")
    {:ok, retry} = Executions.retry_run(run)

    assert Executions.session_progress(Repo.reload!(session)) == %{
             total: 2,
             pending: 1,
             in_flight: 0,
             passed: 0,
             failed: 1,
             skipped: 0
           }

    {:ok, retry} = Executions.start_run(retry)
    {:ok, retry} = Executions.close_run(retry, status: "passed", outcome: "ok")
    assert retry.status == "passed"

    # El cierre pasa la sesión: todos los runs terminales, ninguno failed.
    assert Repo.get!(WorkflowSession, session.id).status == "passed"
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Ownership — un agente hereda el workflow completo (la sesión es SU pasada)
  # ──────────────────────────────────────────────────────────────────────────

  defp make_actor(tag) do
    {:ok, actor} =
      Dran.Actors.create_actor(%{
        "name" => "#{tag}-#{System.unique_integer([:positive])}",
        "kind" => "agent"
      })

    actor
  end

  test "ownership: another actor cannot claim, progress or close a run of an owned session",
       %{ws: ws} do
    owner = make_actor("owner")
    stranger = make_actor("stranger")
    {workflow, [step]} = new_workflow(ws, ["Step"])

    {:ok, session} = Executions.open_session(workflow, actor_id: owner.id)
    [run] = runs_by_step(session, [step.id])

    # El no-dueño no puede ni arrancarlo.
    assert {:error, :not_run_owner} = Executions.start_run(run, actor_id: stranger.id)
    assert Repo.get!(Run, run.id).status == "pending"

    # Dueño lo cierra (único step → la sesión auto-cierra passed).
    {:ok, run} = Executions.start_run(run, actor_id: owner.id)
    {:ok, _} = Executions.close_run(run, %{status: "passed", outcome: "ok"}, actor_id: owner.id)

    # Start tardío de un stranger: rechazado (sesión cerrada).
    assert {:error, :session_closed} = Executions.start_run(run, actor_id: stranger.id)
  end

  test "ownership: progress and close of an in_flight run reject the non-owner", %{ws: ws} do
    owner = make_actor("owner")
    stranger = make_actor("stranger")
    {workflow, [step]} = new_workflow(ws, ["Step"])

    {:ok, session} = Executions.open_session(workflow, actor_id: owner.id)
    [run] = runs_by_step(session, [step.id])
    {:ok, run} = Executions.start_run(run, actor_id: owner.id)

    assert {:error, :not_run_owner} =
             Executions.update_progress(run.id, %{"phase" => "hijacked"}, actor_id: stranger.id)

    assert {:error, :not_run_owner} =
             Executions.close_run(run, %{status: "passed"}, actor_id: stranger.id)

    # Sin efectos: el run sigue en vuelo con su dueño.
    fresh = Repo.get!(Run, run.id)
    assert fresh.status == "in_flight"
    assert fresh.progress == %{}
    assert fresh.actor_id == owner.id
  end

  test "ownership: list_pending_runs hides owned sessions from other actors", %{ws: ws} do
    owner = make_actor("owner")
    stranger = make_actor("stranger")
    {workflow, [a, b]} = new_workflow(ws, ["A", "B"])
    {:ok, _} = Contracts.add_dependency(b, a)
    {open_wf, [open_step]} = new_workflow(ws, ["Open queue"])

    {:ok, _owned} = Executions.open_session(workflow, actor_id: owner.id)
    {:ok, unowned} = Executions.open_session(open_wf)

    # El dueño ve lo ready de SU sesión MÁS la cola abierta (ordenado por
    # inserted_at: la sesión stampada se abrió primero).
    assert Enum.map(Executions.list_pending_runs(ws.id, actor_id: owner.id), & &1.step_id) ==
             [a.id, open_step.id]

    # El stranger solo ve la cola abierta (sesión sin actor).
    stranger_steps = Executions.list_pending_runs(ws.id, actor_id: stranger.id)
    assert Enum.map(stranger_steps, & &1.step_id) == [open_step.id]

    # Un pull sin actor (anonymous) tampoco ve lo stampado — solo la cola abierta.
    assert Enum.map(Executions.list_pending_runs(ws.id), & &1.step_id) == [open_step.id]

    # El primer reclamante de un run sin dueño lo estampa y se lo queda.
    [unowned_run] = runs_by_step(unowned, [open_step.id])
    {:ok, claimed} = Executions.start_run(unowned_run, actor_id: stranger.id)
    assert claimed.actor_id == stranger.id

    # Y tras el claim, el pull anónimo ya no lo ve (quedó stampado).
    assert Executions.list_pending_runs(ws.id) == []

    # El otro actor tampoco lo ve (run en vuelo, y además suyo).
    refute Enum.any?(
             Executions.list_pending_runs(ws.id, actor_id: owner.id),
             &(&1.id == claimed.id)
           )
  end

  test "ownership: retry keeps the owner and the new attempt stays owner-bound", %{ws: ws} do
    owner = make_actor("owner")
    stranger = make_actor("stranger")
    {workflow, [step]} = new_workflow(ws, ["Step"])

    {:ok, session} = Executions.open_session(workflow, actor_id: owner.id)
    [run] = runs_by_step(session, [step.id])
    {:ok, run} = Executions.start_run(run, actor_id: owner.id)

    {:ok, failed} =
      Executions.close_run(run, %{status: "failed", outcome: "flaky"}, actor_id: owner.id)

    {:ok, retry} = Executions.retry_run(failed)
    assert retry.actor_id == owner.id

    assert {:error, :not_run_owner} = Executions.start_run(retry, actor_id: stranger.id)
    {:ok, retry} = Executions.start_run(retry, actor_id: owner.id)
    assert retry.actor_id == owner.id
  end

  # ──────────────────────────────────────────────────────────────────────────
  # list_pending_runs — el pull de agentes (F3 surface)
  # ──────────────────────────────────────────────────────────────────────────

  test "list_pending_runs offers only ready runs of open sessions, scoped by workflow", %{
    ws: ws
  } do
    {workflow, [a, b]} = new_workflow(ws, ["A", "B"])
    {:ok, _} = Contracts.add_dependency(b, a)

    {other, [other_step]} = new_workflow(ws, ["Other"])

    {:ok, session} = Executions.open_session(workflow)
    {:ok, other_session} = Executions.open_session(other)

    # b depende de a: solo a está ready.
    pending = Executions.list_pending_runs(ws.id)

    assert Enum.map(pending, & &1.step_id) |> MapSet.new() ==
             MapSet.new([a.id, other_step.id])

    # Filtro por workflow.
    pending_wf = Executions.list_pending_runs(ws.id, workflow_id: workflow.id)
    assert Enum.map(pending_wf, & &1.step_id) == [a.id]

    # a pasa → b queda offered.
    [run_a] = runs_by_step(session, [a.id])
    {:ok, run_a} = Executions.start_run(run_a)
    {:ok, _} = Executions.close_run(run_a, status: "passed", outcome: "ok")

    pending_wf = Executions.list_pending_runs(ws.id, workflow_id: workflow.id)
    assert Enum.map(pending_wf, & &1.step_id) == [b.id]

    # Una sesión cerrada no ofrece runs.
    {:ok, _} = Executions.abort_session(other_session)
    pending_wf = Executions.list_pending_runs(ws.id, workflow_id: other.id)
    assert pending_wf == []
  end

  # ──────────────────────────────────────────────────────────────────────────
  # delete_session — la historia cerrada es borrable (runs cascade por FK)
  # ──────────────────────────────────────────────────────────────────────────

  test "delete_session removes a closed session and cascades its runs", %{ws: ws} do
    {workflow, [step]} = new_workflow(ws, ["Step"])

    {:ok, session} = Executions.open_session(workflow)
    [run] = runs_by_step(session, [step.id])
    {:ok, run} = Executions.start_run(run)
    {:ok, _} = Executions.close_run(run, status: "passed", outcome: "ok")

    # Sesión cerrada (passed) → borrable; sus runs caen con el cascade del FK.
    session = Repo.get!(WorkflowSession, session.id)
    assert {:ok, _} = Executions.delete_session(session)

    assert Repo.get(WorkflowSession, session.id) == nil
    assert Repo.all(from(r in Run, where: r.session_id == ^session.id)) == []
  end

  test "delete_session refuses an in_flight session; abort first", %{ws: ws} do
    {workflow, [_]} = new_workflow(ws, ["Step"])
    {:ok, session} = Executions.open_session(workflow)

    assert {:error, :session_open} =
             Executions.delete_session(Repo.get!(WorkflowSession, session.id))

    assert Repo.get!(WorkflowSession, session.id).status == "in_flight"

    # Tras abortarla, ya es historia cerrada: borrable.
    {:ok, _} = Executions.abort_session(Repo.get!(WorkflowSession, session.id))
    assert {:ok, _} = Executions.delete_session(Repo.get!(WorkflowSession, session.id))
    assert Repo.get(WorkflowSession, session.id) == nil
  end

  test "delete_session of the one_shot's failed pass clears the re-run block", %{ws: ws} do
    {workflow, [step]} = new_workflow(ws, ["Step"])
    {:ok, workflow} = Dran.Workflows.update_workflow(workflow, %{"kind" => "one_shot"})

    {:ok, session} = Executions.open_session(workflow)
    [run] = runs_by_step(session, [step.id])
    {:ok, run} = Executions.start_run(run)
    {:ok, _} = Executions.close_run(run, status: "failed", outcome: "rojo")

    # one_shot con sesión → re-open bloqueado.
    assert {:error, :workflow_already_ran} = Executions.open_session(workflow)

    # Borrar la pasada fallida (historia cerrada) destraba una nueva pasada.
    assert {:ok, _} = Executions.delete_session(Repo.get!(WorkflowSession, session.id))
    assert {:ok, _second} = Executions.open_session(workflow)
  end

  # ──────────────────────────────────────────────────────────────────────────
  # abort_session
  # ──────────────────────────────────────────────────────────────────────────

  test "abort_session skips open runs and closes the session; refusing a closed one", %{
    ws: ws
  } do
    {workflow, [step1, step2]} = new_workflow(ws, ["Step 1", "Step 2"])

    {:ok, session} = Executions.open_session(workflow)
    [run_s1, _run_s2] = runs_by_step(session, [step1.id, step2.id])

    # run_s1 en vuelo; run_s2 pendiente.
    {:ok, run_s1} = Executions.start_run(run_s1)

    {:ok, aborted} = Executions.abort_session(Repo.get!(WorkflowSession, session.id))
    assert aborted.status == "aborted"
    assert aborted.finished_at != nil

    # Los runs abiertos quedan skipped con outcome de abort.
    runs = Executions.list_runs(session)
    skipped = Enum.find(runs, &(&1.status == "skipped"))
    assert skipped.outcome == "session aborted"

    # Ninguna task existe — nada que cancelar ni archivar (P7).
    assert Repo.aggregate(from(t in Dran.Task), :count) == 0

    # Abortar una sesión cerrada: rechazado.
    assert {:error, :session_closed} =
             Executions.abort_session(Repo.get!(WorkflowSession, session.id))
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Helpers
  # ──────────────────────────────────────────────────────────────────────────

  # Crea workflow + steps; specs pueden ser binarios (título) o mapas con
  # :title/:contract (el contrato va a columnas+embeds). Devuelve {workflow, steps}.
  defp new_workflow(ws, step_specs) do
    {:ok, workflow} =
      Workflows.create_workflow(%{
        "workspace_id" => ws.id,
        "title" => "W #{System.unique_integer([:positive])}",
        "slug" => "w-#{System.unique_integer([:positive])}"
      })

    steps =
      Enum.map(step_specs, fn
        title when is_binary(title) ->
          {:ok, step} =
            Workflows.create_step(workflow, %{
              "title" => title,
              "slug" => "step-#{System.unique_integer([:positive])}"
            })

          step

        %{title: title} = spec ->
          attrs = %{
            "title" => title,
            "slug" => "step-#{System.unique_integer([:positive])}"
          }

          attrs =
            case Map.get(spec, :contract) do
              nil -> attrs
              contract -> Map.merge(attrs, contract_attrs(contract))
            end

          {:ok, step} = Workflows.create_step(workflow, attrs)
          step
      end)

    {workflow, steps}
  end

  # JSON contract map → step attrs (columns + embeds). Normaliza los campos
  # del contrato al shape del schema: claim (no "text"), gates con name/
  # cmd/expect, y solo claves editables (status/versión son columnas).
  defp contract_attrs(contract) do
    %{"intent" => contract["intent"]}
    |> put_claims(contract["claims"])
    |> put_gates(contract["gates"])
    |> put_graph(contract["graph"])
  end

  defp put_claims(attrs, claims) when is_list(claims) do
    Map.put(
      attrs,
      "claims",
      Enum.map(claims, fn c ->
        %{"id" => c["id"], "claim" => c["claim"] || c["text"], "verify" => c["verify"]}
      end)
    )
  end

  defp put_claims(attrs, _), do: attrs

  defp put_gates(attrs, gates) when is_list(gates) do
    Map.put(
      attrs,
      "gates",
      Enum.map(gates, fn g ->
        %{
          "name" => g["name"] || g["id"] || "gate",
          "cmd" => g["cmd"],
          "expect" => g["expect"] || "exit 0"
        }
      end)
    )
  end

  defp put_gates(attrs, _), do: attrs

  defp put_graph(attrs, %{"nodes" => _} = graph), do: Map.put(attrs, "graph", graph)
  defp put_graph(attrs, _), do: attrs

  defp runs_by_step(session, step_ids) do
    runs = Executions.list_runs(session)

    Enum.map(step_ids, fn step_id ->
      Enum.find(runs, &(&1.step_id == step_id))
    end)
  end
end
