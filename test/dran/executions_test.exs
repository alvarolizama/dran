defmodule Dran.ExecutionsTest do
  @moduledoc """
  Wave B — executions re-pointed to plans: open_session(plan) with frozen
  plan_snapshot, runs per step, task spawn in start_run (instance_of step +
  part_of goal), dual closure converging (close_run agent-side +
  reconcile_task_closure board-side), spawned tasks archived on session
  close, abort cancels in-flight spawned tasks.

  Full port of every F1 case, re-keyed from tasks to steps, plus the new
  wave-B surface (spawn, snapshot, reconcile, archive). Concurrency
  guarantees preserved: conditional claims, transactional close, retry
  superseded.
  """

  use Dran.DataCase, async: true

  import Ecto.Query

  alias Dran.{
    Contracts,
    Executions,
    GoalSession,
    Goals,
    Knowledge,
    Plan,
    Plans,
    Relation,
    Repo,
    TaskRun,
    Tasks
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
  # P1 — open_session(plan) con runs upfront + snapshot congelado
  # ──────────────────────────────────────────────────────────────────────────

  test "P1: open_session(plan) creates pending runs upfront for every step of the plan", %{
    ws: ws
  } do
    {goal, plan, steps} = new_plan(ws, ["Step 1", "Step 2"])

    {:ok, session} = Executions.open_session(plan, label: "release 1")

    session = Repo.preload(session, :runs)
    assert session.status == "in_flight"
    assert session.label == "release 1"
    assert session.plan_id == plan.id
    # goal_id denormalizado = el goal que el plan sirve.
    assert session.goal_id == goal.id

    run_step_ids = Enum.map(session.runs, & &1.step_id) |> MapSet.new()
    assert run_step_ids == MapSet.new(Enum.map(steps, & &1.id))
    assert Enum.all?(session.runs, &(&1.status == "pending"))
    assert Enum.all?(session.runs, &(&1.attempt == 1))
    # Sin contrato en los steps → nil (decisión 2).
    assert Enum.all?(session.runs, &(&1.contract_version == nil))
    # Sin spawn todavía: task_id nil hasta start_run.
    assert Enum.all?(session.runs, &(&1.task_id == nil))
  end

  test "P1: open_session(plan) freezes the plan_snapshot with steps and depends_on edges", %{
    ws: ws
  } do
    {_goal, plan, [a, b, c]} = new_plan(ws, ["A", "B", "C"])

    {:ok, _} = Contracts.add_dependency(b, a)
    {:ok, _} = Contracts.add_dependency(c, b)

    {:ok, session} = Executions.open_session(plan)

    snapshot = session.plan_snapshot

    assert snapshot["edges"] |> Enum.map(&List.to_tuple/1) |> MapSet.new() ==
             MapSet.new([{b.id, a.id}, {c.id, b.id}])

    assert snapshot["steps"] |> length() == 3

    assert Enum.map(snapshot["steps"], & &1["id"]) |> MapSet.new() ==
             MapSet.new([a.id, b.id, c.id])

    assert Enum.all?(snapshot["steps"], &is_binary(&1["title"]))
  end

  test "P1: plan_snapshot and contract_version stay frozen when the plan is edited after open", %{
    ws: ws
  } do
    contract = %{
      "intent" => "Ship the login flow",
      "claims" => [%{"id" => "P1", "text" => "form validates", "verify" => "mix test"}],
      "gates" => [%{"id" => "G1", "cmd" => "mix test"}]
    }

    {_goal, plan, [step1]} = new_plan(ws, [%{title: "Contracted step", contract: contract}])

    {:ok, session} = Executions.open_session(plan)
    session = Repo.preload(session, :runs)
    [run] = session.runs
    assert run.contract_version == contract

    assert session.plan_snapshot["steps"] == [
             %{"id" => step1.id, "title" => "Contracted step", "contract" => contract}
           ]

    # El plan muta DESPUÉS de abrir: título del step, contrato del step y un
    # step nuevo — el snapshot de la sesión queda intacto.
    {:ok, _} = Plans.update_step(step1, %{"title" => "Renamed"})

    {:ok, _} =
      Plans.update_step(step1, %{
        "meta" => %{"contract" => Map.put(contract, "intent", "Changed")}
      })

    {:ok, _} = Plans.create_step(plan, %{"title" => "Late", "slug" => "late-step"})

    session = Repo.reload!(session)

    assert session.plan_snapshot["steps"] == [
             %{"id" => step1.id, "title" => "Contracted step", "contract" => contract}
           ]

    # El run conserva el contract_version congelado.
    assert Repo.get!(TaskRun, run.id).contract_version == contract
  end

  test "P1: open_session refuses a plan without a serves goal", %{ws: ws} do
    {:ok, plan} =
      Plans.create_plan(%{
        workspace_id: ws.id,
        title: "Lonely plan",
        slug: "lonely-plan-#{System.unique_integer([:positive])}"
      })

    assert {:error, :plan_serves_no_goal} = Executions.open_session(plan)
  end

  test "P1: open_session with actor_id records the driver; label and context are stored", %{
    ws: ws
  } do
    {_goal, plan, _steps} = new_plan(ws, ["Step"])

    {:ok, actor} =
      Dran.Actors.create_actor(%{
        "name" => "exec-agent-#{System.unique_integer([:positive])}",
        "kind" => "agent"
      })

    {:ok, session} =
      Executions.open_session(plan,
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

  # ──────────────────────────────────────────────────────────────────────────
  # P3 — run_ready? exige prereqs passed EN ESA sesión (ALL)
  # ──────────────────────────────────────────────────────────────────────────

  test "P3: run_ready? requires prerequisites passed in the same session", %{ws: ws} do
    {_goal, plan, [prereq_step, step]} = new_plan(ws, ["Prereq", "Step"])
    {:ok, _} = Contracts.add_dependency(step, prereq_step)

    {:ok, s1} = Executions.open_session(plan)
    {:ok, s2} = Executions.open_session(plan)

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

  test "P3: run_ready? requires ALL prerequisites passed — one of two is not enough", %{ws: ws} do
    {_goal, plan, [pa, pb, final]} = new_plan(ws, ["Prereq A", "Prereq B", "Final step"])

    {:ok, _} = Contracts.add_dependency(final, pa)
    {:ok, _} = Contracts.add_dependency(final, pb)

    {:ok, session} = Executions.open_session(plan)
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

  test "P3: a prerequisite step from another plan has no run in the session — never ready (no board fallback)",
       %{ws: ws} do
    {_goal_a, plan_a, [step_a]} = new_plan(ws, ["Step A"])
    {_goal_b, _plan_b, [external]} = new_plan(ws, ["External step"])

    {:ok, _} = Contracts.add_dependency(step_a, external)

    {:ok, session} = Executions.open_session(plan_a)
    [run_step] = runs_by_step(session, [step_a.id])

    # El prereq externo NO tiene run en la sesión, y los steps no tienen
    # board status al que caer (wave B, sin fallback F1): nunca listo.
    refute Executions.run_ready?(run_step)
  end

  # ──────────────────────────────────────────────────────────────────────────
  # P2 — spawn de task en start_run (instance_of + part_of, idempotente)
  # ──────────────────────────────────────────────────────────────────────────

  test "P2: start_run spawns the task (instance_of step + part_of goal) from the frozen contract",
       %{
         ws: ws
       } do
    contract = %{"intent" => "Build X", "claims" => [], "gates" => []}

    {goal, plan, [step]} =
      new_plan(ws, [%{title: "Contracted step", body: "brief", contract: contract}])

    {:ok, session} = Executions.open_session(plan)
    [run] = runs_by_step(session, [step.id])
    assert run.task_id == nil

    {:ok, started} = Executions.start_run(run)
    assert started.status == "in_flight"
    assert started.task_id != nil

    task = Repo.get!(Dran.Task, started.task_id)
    assert task.title == "Contracted step"
    assert task.body == "brief"
    assert task.status == "todo"
    assert task.workspace_id == ws.id
    # El contrato viene del snapshot congelado del run, no del step vivo.
    assert task.meta["contract"] == contract

    # instance_of task→step y part_of task→goal (las spawned cuentan en el
    # recompute del goal — Snippet 2).
    assert Repo.exists?(
             from r in Relation,
               where:
                 r.source_id == ^task.id and r.source_type == "task" and
                   r.target_id == ^step.id and r.target_type == "step" and
                   r.relation_type == "instance_of"
           )

    assert Repo.exists?(
             from r in Relation,
               where:
                 r.source_id == ^task.id and r.target_id == ^goal.id and
                   r.relation_type == "part_of"
           )
  end

  test "P2: spawn is idempotent — a run that already has a task is never re-spawned", %{ws: ws} do
    {_goal, plan, [step]} = new_plan(ws, ["Step"])
    {:ok, session} = Executions.open_session(plan)
    [run] = runs_by_step(session, [step.id])

    {:ok, started} = Executions.start_run(run)
    assert started.task_id != nil

    # Doble start con el MISMO struct pending: pierde el claim condicional.
    assert {:error, {:wrong_status, "in_flight", "pending"}} = Executions.start_run(run)

    # Re-intento con el run REAL de la BD (in_flight): el claim condicional
    # vuelve a fallar. El spawn nunca puede dispararse dos veces porque sólo
    # corre DESPUÉS de un claim exitoso (guard F1 preservado).
    assert {:error, {:wrong_status, "in_flight", "pending"}} =
             Executions.start_run(Repo.get!(TaskRun, started.id))

    # Sólo UNA task se creó y el run conserva la misma spawned.
    assert Repo.aggregate(from(t in Dran.Task, where: t.title == "Step"), :count) == 1
    assert Repo.get!(TaskRun, started.id).task_id == started.task_id
  end

  # ──────────────────────────────────────────────────────────────────────────
  # P4 + P3 — cierre agente (close_run) con writeback sobre la spawned
  # ──────────────────────────────────────────────────────────────────────────

  test "P4: closing the last run closes the session (passed), archives the spawned and recomputes the goal",
       %{ws: ws} do
    {_goal, plan, [step1, step2]} = new_plan(ws, ["Step 1", "Step 2"])
    # Una task MANUAL part_of del goal (no spawn): el recompute del cierre
    # la cuenta — spawned archivadas salen del denominador.
    {:ok, manual} =
      Tasks.create_task(%{"workspace_id" => ws.id, "title" => "Manual board task"})

    goal = Goals.get_goal(plan_goal_id(plan))
    Tasks.link_to_goal(manual, goal)
    {:ok, _} = Tasks.update_task(manual, %{"status" => "done"})

    {:ok, session} = Executions.open_session(plan)
    [run_s1, run_s2] = runs_by_step(session, [step1.id, step2.id])

    # La sesión sigue abierta tras el primer cierre (queda un run pending).
    {:ok, run_s1} = Executions.start_run(run_s1)
    {:ok, _} = Executions.close_run(run_s1, status: "passed", outcome: "ok")
    assert Repo.get(GoalSession, session.id).status == "in_flight"

    # Run passed → writeback done a la task SPAWNED (decisión ?03).
    task1 = Repo.get!(Dran.Task, run_s1.task_id)
    assert task1.status == "done"

    {:ok, run_s2} = Executions.start_run(run_s2)
    {:ok, _} = Executions.close_run(run_s2, status: "passed", outcome: "ok")
    closed = Repo.get!(GoalSession, session.id)
    assert closed.status == "passed"
    assert closed.finished_at != nil

    # Todas las spawned de la sesión quedan archivadas (?07) — con status
    # terminal intacto.
    assert Repo.get!(Dran.Task, run_s1.task_id).archived
    task2 = Repo.get!(Dran.Task, run_s2.task_id)
    assert task2.status == "done"
    assert task2.archived

    # El recompute del cierre corre sobre goal_id denormalizado: la manual
    # done (1/1) da progreso 1.0 — las spawned archivadas no cuentan.
    goal = Goals.get_goal(goal.id)
    assert goal.progress == 1.0
    assert goal.meta["progress_derived"] == true
  end

  test "P4: a failed run closes the session as failed and never touches the spawned task status",
       %{
         ws: ws
       } do
    {_goal, plan, [_step]} = new_plan(ws, ["Only step"])

    {:ok, session} = Executions.open_session(plan)
    [run] = runs_by_step(session, [first_step_id(plan)])

    {:ok, run} = Executions.start_run(run)
    {:ok, _run} = Executions.close_run(run, status: "failed", outcome: "gate G2 fell")

    closed = Repo.get!(GoalSession, session.id)
    assert closed.status == "failed"
    assert closed.finished_at != nil

    # failed NO toca task.status (decisión ?03 — el retry la cancela).
    task = Repo.get!(Dran.Task, run.task_id)
    assert task.status == "todo"
    # El auto-cierre archiva también las spawned de una sesión failed.
    assert task.archived
  end

  test "P4: writeback is idempotent — a task already done by the board is not re-triggered", %{
    ws: ws
  } do
    {_goal, plan, [_step]} = new_plan(ws, ["Step"])

    {:ok, session} = Executions.open_session(plan)
    [run] = runs_by_step(session, [first_step_id(plan)])
    {:ok, run} = Executions.start_run(run)

    # El humano marca done a la spawned ANTES de que el agente cierre — el
    # wiring del board reconcilia DENTRO de update_task: el run ya pasó.
    spawn_task = Repo.get!(Dran.Task, run.task_id)
    {:ok, _} = Tasks.update_task(spawn_task, %{"status" => "done"})

    run_after = Repo.get!(Dran.TaskRun, run.id)
    assert run_after.status == "passed"
    assert run_after.outcome == "manual"
    assert Repo.get!(Dran.Task, run.task_id).status == "done"

    # Cerrar por agente un run ya reconciliado: rechazado limpio (no in_flight).
    assert {:error, :not_in_flight} = Executions.close_run(run, status: "passed", outcome: "ok")
  end

  test "P4: a skipped run cancels the spawned task and still closes the session as passed", %{
    ws: ws
  } do
    {_goal, plan, [do_step, skip_step]} = new_plan(ws, ["Do", "Skip me"])

    {:ok, session} = Executions.open_session(plan)
    [run_do, run_skip] = runs_by_step(session, [do_step.id, skip_step.id])

    {:ok, run_do} = Executions.start_run(run_do)
    {:ok, _} = Executions.close_run(run_do, status: "passed", outcome: "ok")

    {:ok, run_skip} = Executions.start_run(run_skip)
    spawned_skip = Repo.get!(Dran.Task, run_skip.task_id)
    assert spawned_skip.status == "todo"

    {:ok, _} = Executions.close_run(run_skip, status: "skipped", outcome: "fuera de alcance")

    # skipped → la spawned se CANCELA (wave B), no queda en el board.
    assert Repo.get!(Dran.Task, run_skip.task_id).status == "cancelled"

    # ...y cuenta como cierre válido: sesión passed.
    closed = Repo.get!(GoalSession, session.id)
    assert closed.status == "passed"
    assert closed.finished_at != nil
  end

  # ──────────────────────────────────────────────────────────────────────────
  # P3 — cierre dual converge (reconcile_task_closure humano)
  # ──────────────────────────────────────────────────────────────────────────

  test "P3: reconcile_task_closure closes the run when the human marks the spawned task done (board path)",
       %{ws: ws} do
    {_goal, plan, [step1, step2]} = new_plan(ws, ["Step 1", "Step 2"])

    {:ok, session} = Executions.open_session(plan)
    [run_s1, run_s2] = runs_by_step(session, [step1.id, step2.id])

    # Camino agente: close_run terminaliza la spawned.
    {:ok, run_s1} = Executions.start_run(run_s1)
    {:ok, _} = Executions.close_run(run_s1, status: "passed", outcome: "ok")
    assert Repo.get!(Dran.Task, run_s1.task_id).status == "done"

    # Camino humano: la spawned de s2 llega a done por el BOARD — el wiring
    # de update_task reconcilia DENTRO (run passed, outcome manual, gates {}).
    {:ok, run_s2} = Executions.start_run(run_s2)
    spawned2 = Repo.get!(Dran.Task, run_s2.task_id)
    {:ok, _} = Tasks.update_task(spawned2, %{"status" => "done"})

    reconciled = Repo.get!(Dran.TaskRun, run_s2.id)
    assert reconciled.status == "passed"
    assert reconciled.outcome == "manual"
    assert reconciled.gate_results == %{}

    # Ambos caminos convergen: último run cerrado → sesión passed y las
    # spawned (de ambos caminos) archivadas.
    closed = Repo.get!(GoalSession, session.id)
    assert closed.status == "passed"
    assert closed.finished_at != nil
    assert Repo.get!(Dran.Task, run_s1.task_id).archived
    assert Repo.get!(Dran.Task, run_s2.task_id).archived
  end

  test "P3: reconcile_task_closure closes the run as skipped when the human cancels the spawned task",
       %{
         ws: ws
       } do
    {_goal, plan, [_step]} = new_plan(ws, ["Step"])

    {:ok, session} = Executions.open_session(plan)
    [run] = runs_by_step(session, [first_step_id(plan)])
    {:ok, run} = Executions.start_run(run)

    spawned = Repo.get!(Dran.Task, run.task_id)
    {:ok, _} = Tasks.update_task(spawned, %{"status" => "cancelled"})

    # El wiring de update_task ya reconcilió: run skipped con outcome manual.
    reconciled = Repo.get!(Dran.TaskRun, run.id)
    assert reconciled.status == "skipped"
    assert reconciled.outcome == "manual"

    closed = Repo.get!(GoalSession, session.id)
    assert closed.status == "passed"
    assert Repo.get!(Dran.Task, run.task_id).archived
  end

  test "P3: reconcile_task_closure is a no-op without an in_flight run for the task", %{ws: ws} do
    # Task que nunca se spawneó (board puro).
    {:ok, plain} = Tasks.create_task(%{"workspace_id" => ws.id, "title" => "Plain board task"})
    assert {:ok, :noop} = Executions.reconcile_task_closure(plain)

    # Spawned cuyo run ya cerró el agente.
    {_goal, plan, [_step]} = new_plan(ws, ["Step"])
    {:ok, session} = Executions.open_session(plan)
    [run] = runs_by_step(session, [first_step_id(plan)])
    {:ok, run} = Executions.start_run(run)
    {:ok, _} = Executions.close_run(run, status: "passed", outcome: "ok")

    assert {:ok, :noop} = Executions.reconcile_task_closure(Repo.get!(Dran.Task, run.task_id))
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Retry semantics (superseded + cancel de la task del intento fallido)
  # ──────────────────────────────────────────────────────────────────────────

  test "retry_run creates a new attempt for the same (session, step), cancels the failed task and reopens a failed session",
       %{ws: ws} do
    {_goal, plan, [step1]} = new_plan(ws, ["Step"])

    {:ok, session} = Executions.open_session(plan)
    [run] = runs_by_step(session, [step1.id])

    {:ok, run} = Executions.start_run(run)
    task1 = Repo.get!(Dran.Task, run.task_id)
    {:ok, failed_run} = Executions.close_run(run, status: "failed", outcome: "flaky")

    # Auto-cierre failed (un solo step).
    assert Repo.get!(GoalSession, session.id).status == "failed"

    # Retry legítimo: reabre la sesión y crea attempt 2 (sin spawn aún).
    {:ok, retry} = Executions.retry_run(failed_run)
    assert retry.session_id == session.id
    assert retry.step_id == step1.id
    assert retry.task_id == nil
    assert retry.attempt == 2
    assert retry.status == "pending"
    assert Repo.get!(GoalSession, session.id).status == "in_flight"

    # La task del intento fallido se CANCELA (decisión ?05) — sigue
    # archivada por el auto-cierre que la precedió.
    task1 = Repo.get!(Dran.Task, task1.id)
    assert task1.status == "cancelled"
    assert task1.archived

    runs = Executions.list_runs(session)
    assert length(runs) == 2
    assert Enum.count(runs, &(&1.status == "failed")) == 1
    assert Enum.count(runs, &(&1.status == "pending")) == 1
  end

  test "retry of a superseded attempt is rejected and never corrupts a closed session", %{ws: ws} do
    {_goal, plan, [step1]} = new_plan(ws, ["Step"])

    {:ok, session} = Executions.open_session(plan)
    [run] = runs_by_step(session, [step1.id])

    {:ok, run} = Executions.start_run(run)
    {:ok, failed_run} = Executions.close_run(run, status: "failed", outcome: "flaky")

    {:ok, retry} = Executions.retry_run(failed_run)
    {:ok, retry} = Executions.start_run(retry)
    {:ok, _} = Executions.close_run(retry, status: "passed", outcome: "ok")

    closed = Repo.get!(GoalSession, session.id)
    assert closed.status == "passed"
    assert closed.finished_at != nil

    # Un retry del attempt 1 VIEJO (struct failed en mano del caller):
    # rechazado SIN reabrir ni corromper la sesión cerrada.
    assert {:error, {:superseded, "passed"}} = Executions.retry_run(failed_run)
    still_closed = Repo.get!(GoalSession, session.id)
    assert still_closed.status == "passed"
    assert still_closed.finished_at == closed.finished_at
  end

  test "retry after a failed auto-close reopens the session (decision 6, happy path)", %{ws: ws} do
    {_goal, plan, [step1]} = new_plan(ws, ["Step"])

    {:ok, session} = Executions.open_session(plan)
    [run] = runs_by_step(session, [step1.id])

    {:ok, run} = Executions.start_run(run)
    {:ok, run} = Executions.close_run(run, status: "failed", outcome: "gate rojo")

    assert Repo.get!(GoalSession, session.id).status == "failed"

    {:ok, retry} = Executions.retry_run(run)
    assert retry.status == "pending"
    assert Repo.get!(GoalSession, session.id).status == "in_flight"
    assert Repo.get!(GoalSession, session.id).finished_at == nil
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Concurrency guards (claims condicionales, port F1)
  # ──────────────────────────────────────────────────────────────────────────

  test "start_run on a stale struct loses: only one claim wins (no double spawn)", %{ws: ws} do
    {_goal, plan, [step1]} = new_plan(ws, ["Step"])

    {:ok, session} = Executions.open_session(plan)
    [run] = runs_by_step(session, [step1.id])

    # Dos dispatchers sostienen el MISMO struct pending; el update
    # condicional (WHERE status='pending') deja pasar a uno solo.
    {:ok, claimed} = Executions.start_run(run)
    assert claimed.status == "in_flight"

    assert {:error, {:wrong_status, "in_flight", "pending"}} = Executions.start_run(run)
    assert Repo.get!(TaskRun, run.id).status == "in_flight"
    assert Repo.aggregate(from(t in Dran.Task, where: t.title == "Step"), :count) == 1
  end

  test "close_run on a stale/pending run is rejected without side effects", %{ws: ws} do
    {_goal, plan, [step1]} = new_plan(ws, ["Step"])

    {:ok, session} = Executions.open_session(plan)
    [run] = runs_by_step(session, [step1.id])

    # close_run sobre un run pending: {:error, :not_in_flight}, sin efectos.
    assert {:error, :not_in_flight} = Executions.close_run(run, status: "passed")
    assert Repo.get!(TaskRun, run.id).status == "pending"
    assert Repo.get!(GoalSession, session.id).status == "in_flight"

    # Doble cierre con el MISMO struct in_flight: el segundo pierde.
    {:ok, run} = Executions.start_run(run)
    task_id = run.task_id
    {:ok, _} = Executions.close_run(run, status: "passed", outcome: "first")

    stale = %TaskRun{run | status: "in_flight"}

    assert {:error, :not_in_flight} =
             Executions.close_run(stale, status: "failed", outcome: "second")

    assert Repo.get!(TaskRun, run.id).status == "passed"
    assert Repo.get!(Dran.Task, task_id).status == "done"
  end

  test "start_run on a closed session is rejected", %{ws: ws} do
    {_goal, plan, [step1]} = new_plan(ws, ["Step"])

    {:ok, session} = Executions.open_session(plan)
    [run] = runs_by_step(session, [step1.id])
    {:ok, run} = Executions.start_run(run)
    {:ok, _} = Executions.close_run(run, status: "passed", outcome: "ok")

    # La sesión auto-cerró passed. Una segunda sesión abortada deja un run
    # pending fantasma: un start tardío no puede arrancarlo.
    {:ok, session2} = Executions.open_session(plan, label: "second pass")
    [%TaskRun{} = run2] = runs_by_step(session2, [step1.id])
    {:ok, _} = Executions.abort_session(session2)

    stale = %TaskRun{run2 | status: "pending"}
    assert {:error, :session_closed} = Executions.start_run(stale)
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Misc API (progress, invalid status)
  # ──────────────────────────────────────────────────────────────────────────

  test "session_progress counts runs by status and retries count too", %{ws: ws} do
    {_goal, plan, [step1]} = new_plan(ws, ["Step"])

    {:ok, session} = Executions.open_session(plan)

    assert Executions.session_progress(session) == %{
             total: 1,
             pending: 1,
             in_flight: 0,
             passed: 0,
             failed: 0,
             skipped: 0
           }

    [run] = runs_by_step(session, [step1.id])
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
    assert Repo.get!(GoalSession, session.id).status == "passed"
    assert Repo.get!(Dran.Task, retry.task_id).status == "done"
  end

  test "invalid close status is rejected without side effects", %{ws: ws} do
    {_goal, plan, [step1]} = new_plan(ws, ["Step"])

    {:ok, session} = Executions.open_session(plan)
    [run] = runs_by_step(session, [step1.id])
    {:ok, _} = Executions.start_run(run)

    assert {:error, :invalid_status} = Executions.close_run(run, status: "banana")
    assert Repo.get!(TaskRun, run.id).status == "in_flight"
    assert Repo.get!(GoalSession, session.id).status == "in_flight"
  end

  # ──────────────────────────────────────────────────────────────────────────
  # abort_session — cancela in-flight spawned + archiva todo + recompute
  # ──────────────────────────────────────────────────────────────────────────

  test "abort_session cancels the in-flight spawned task, archives every spawned, skips open runs and recomputes",
       %{ws: ws} do
    {_goal, plan, [step1, step2]} = new_plan(ws, ["Step 1", "Step 2"])

    {:ok, session} = Executions.open_session(plan)
    [run_s1, _run_s2] = runs_by_step(session, [step1.id, step2.id])

    # run_s1 en vuelo (spawned todo); run_s2 pendiente sin spawn.
    {:ok, run_s1} = Executions.start_run(run_s1)
    spawned1 = Repo.get!(Dran.Task, run_s1.task_id)
    assert spawned1.status == "todo"

    {:ok, aborted} = Executions.abort_session(Repo.get!(GoalSession, session.id))
    assert aborted.status == "aborted"
    assert aborted.finished_at != nil

    # El run en vuelo fue skipped con outcome de abort.
    runs = Executions.list_runs(session)
    skipped = Enum.find(runs, &(&1.status == "skipped"))
    assert skipped.outcome == "session aborted"

    # La spawned in-flight se CANCELA y TODAS las spawned se archivan
    # (decisión ?05 + ?07).
    spawned1 = Repo.get!(Dran.Task, spawned1.id)
    assert spawned1.status == "cancelled"
    assert spawned1.archived

    # El run pendiente (sin spawn) no deja tasks huérfanas.
    refute Repo.exists?(from t in Dran.Task, where: t.title == "Step 2")

    # Abortar una sesión cerrada: rechazado.
    assert {:error, :session_closed} =
             Executions.abort_session(Repo.get!(GoalSession, session.id))
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Helpers
  # ──────────────────────────────────────────────────────────────────────────

  # Crea goal + plan (serves) + steps; specs pueden ser binarios (título) o
  # mapas con :title/:body/:contract. Devuelve {goal, plan, steps}.
  defp new_plan(ws, step_specs) do
    {:ok, goal} =
      Goals.create_goal(%{
        "workspace_id" => ws.id,
        "title" => "Goal #{System.unique_integer([:positive])}",
        "slug" => "goal-#{System.unique_integer([:positive])}"
      })

    {:ok, plan} =
      Plans.create_plan(%{
        "workspace_id" => ws.id,
        "title" => "Plan #{System.unique_integer([:positive])}",
        "slug" => "plan-#{System.unique_integer([:positive])}"
      })

    {:ok, _} =
      Knowledge.create_relation(%{
        source_id: plan.id,
        source_type: "plan",
        target_id: goal.id,
        target_type: "goal",
        relation_type: "serves"
      })

    steps =
      Enum.map(step_specs, fn
        title when is_binary(title) ->
          {:ok, step} =
            Plans.create_step(plan, %{
              "title" => title,
              "slug" => "step-#{System.unique_integer([:positive])}"
            })

          step

        %{title: title} = spec ->
          attrs = %{
            "title" => title,
            "slug" => "step-#{System.unique_integer([:positive])}",
            "body" => Map.get(spec, :body, "")
          }

          attrs =
            case Map.get(spec, :contract) do
              nil -> attrs
              contract -> Map.put(attrs, "meta", %{"contract" => contract})
            end

          {:ok, step} = Plans.create_step(plan, attrs)
          step
      end)

    {goal, plan, steps}
  end

  defp first_step_id(%Plan{} = plan) do
    [%{id: id} | _] = Dran.Plans.list_steps(plan)
    id
  end

  defp plan_goal_id(%Plan{} = plan) do
    Repo.one(
      from r in Relation,
        where:
          r.source_id == ^plan.id and r.source_type == "plan" and
            r.target_type == "goal" and r.relation_type == "serves",
        select: r.target_id
    )
  end

  defp runs_by_step(session, step_ids) do
    runs = Executions.list_runs(session)

    Enum.map(step_ids, fn step_id ->
      Enum.find(runs, &(&1.step_id == step_id))
    end)
  end
end
