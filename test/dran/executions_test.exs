defmodule Dran.ExecutionsTest do
  use Dran.DataCase, async: true

  alias Dran.{Contracts, Executions, GoalSession, Goals, Repo, TaskRun, Tasks}

  setup do
    {:ok, ws} =
      Dran.Knowledge.create_workspace(%{
        name: "Executions WS #{System.unique_integer([:positive])}",
        slug: "exec-ws-#{System.unique_integer([:positive])}"
      })

    {:ok, ws: ws}
  end

  # ──────────────────────────────────────────────────────────────────────────
  # P1 — abrir sesión crea runs pending de todos los pasos del goal
  # ──────────────────────────────────────────────────────────────────────────

  test "P1: open_session creates pending runs for every active step (no archived, no cancelled, no recurring)",
       %{
         ws: ws
       } do
    {:ok, goal} = new_goal(ws, "Ship feature", "ship-feature")
    {:ok, t1} = Tasks.create_task(%{"workspace_id" => ws.id, "title" => "Step 1"})
    {:ok, t2} = Tasks.create_task(%{"workspace_id" => ws.id, "title" => "Step 2"})

    {:ok, recurring} =
      Tasks.create_task(%{
        "workspace_id" => ws.id,
        "title" => "Recurring step",
        "recurrence" => "weekly"
      })

    {:ok, archived} =
      Tasks.create_task(%{
        "workspace_id" => ws.id,
        "title" => "Archived step",
        "archived" => true
      })

    {:ok, cancelled} =
      Tasks.create_task(%{
        "workspace_id" => ws.id,
        "title" => "Cancelled step",
        "status" => "cancelled"
      })

    Tasks.link_to_goal(t1, goal)
    Tasks.link_to_goal(t2, goal)
    Tasks.link_to_goal(recurring, goal)
    Tasks.link_to_goal(archived, goal)
    Tasks.link_to_goal(cancelled, goal)

    {:ok, session} = Executions.open_session(goal, label: "release 1")

    session = Repo.preload(session, :runs)
    assert session.status == "in_flight"
    assert session.label == "release 1"

    # Decisión 4: recurrentes EXCLUIDAS; decisión 5: archived/cancelled fuera.
    run_ids = Enum.map(session.runs, & &1.task_id) |> MapSet.new()
    assert run_ids == MapSet.new([t1.id, t2.id])
    assert Enum.all?(session.runs, &(&1.status == "pending"))
    assert Enum.all?(session.runs, &(&1.attempt == 1))

    # Snapshot del contrato al abrir (decisión 2): nil sin contrato.
    assert Enum.all?(session.runs, &(&1.contract_version == nil))
  end

  # ──────────────────────────────────────────────────────────────────────────
  # P3 — run ready exige prereqs passed EN ESA sesión
  # ──────────────────────────────────────────────────────────────────────────

  test "P3: run_ready? requires prerequisites passed in the same session", %{ws: ws} do
    {:ok, goal} = new_goal(ws, "Two sessions", "two-sessions")
    {:ok, prereq} = Tasks.create_task(%{"workspace_id" => ws.id, "title" => "Prereq"})
    {:ok, step} = Tasks.create_task(%{"workspace_id" => ws.id, "title" => "Step"})

    Tasks.link_to_goal(prereq, goal)
    Tasks.link_to_goal(step, goal)

    {:ok, _} = Contracts.add_dependency(step, prereq)

    {:ok, s1} = Executions.open_session(goal)
    {:ok, s2} = Executions.open_session(goal)

    [step_run_s1, prereq_run_s1] = runs_by_task(s1, [step.id, prereq.id])
    [step_run_s2, prereq_run_s2] = runs_by_task(s2, [step.id, prereq.id])

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
    {:ok, goal} = new_goal(ws, "Diamond", "diamond-goal")
    {:ok, pa} = Tasks.create_task(%{"workspace_id" => ws.id, "title" => "Prereq A"})
    {:ok, pb} = Tasks.create_task(%{"workspace_id" => ws.id, "title" => "Prereq B"})
    {:ok, step} = Tasks.create_task(%{"workspace_id" => ws.id, "title" => "Final step"})

    Tasks.link_to_goal(pa, goal)
    Tasks.link_to_goal(pb, goal)
    Tasks.link_to_goal(step, goal)

    {:ok, _} = Contracts.add_dependency(step, pa)
    {:ok, _} = Contracts.add_dependency(step, pb)

    {:ok, session} = Executions.open_session(goal)
    [run_pa, run_pb, run_step] = runs_by_task(session, [pa.id, pb.id, step.id])

    refute Executions.run_ready?(run_step)

    # Solo A pasa: el paso SIGUE bloqueado (exige TODOS los prereqs).
    {:ok, run_pa} = Executions.start_run(run_pa)
    {:ok, _} = Executions.close_run(run_pa, status: "passed", outcome: "ok")
    refute Executions.run_ready?(run_step)

    # B falla y se reintenta con éxito: el latest attempt (passed) cuenta.
    {:ok, run_pb} = Executions.start_run(run_pb)
    {:ok, run_pb} = Executions.close_run(run_pb, status: "failed", outcome: "flaky")
    {:ok, retry_pb} = Executions.retry_run(run_pb)
    {:ok, retry_pb} = Executions.start_run(retry_pb)
    {:ok, _} = Executions.close_run(retry_pb, status: "passed", outcome: "ok")

    assert Executions.run_ready?(run_step)
  end

  test "P4: closing the last run closes the session (passed) and recomputes the goal", %{
    ws: ws
  } do
    {:ok, goal} = new_goal(ws, "One shot", "one-shot")
    {:ok, t1} = Tasks.create_task(%{"workspace_id" => ws.id, "title" => "Step 1"})
    {:ok, t2} = Tasks.create_task(%{"workspace_id" => ws.id, "title" => "Step 2"})

    Tasks.link_to_goal(t1, goal)
    Tasks.link_to_goal(t2, goal)

    {:ok, session} = Executions.open_session(goal)
    [run_t1, run_t2] = runs_by_task(session, [t1.id, t2.id])

    # Progress derivado arranca en 0.0 (ninguna task done).
    goal = Goals.get_goal(goal.id)
    assert goal.progress == 0.0
    assert goal.meta["progress_derived"] == true

    {:ok, run_t1} = Executions.start_run(run_t1)
    {:ok, _run_t1} = Executions.close_run(run_t1, status: "passed", outcome: "ok")

    # La sesión sigue abierta (quedan runs pending).
    assert Repo.get(GoalSession, session.id).status == "in_flight"

    # Run t1 passed → writeback a la task (decisión 3).
    assert Repo.get!(Dran.Task, t1.id).status == "done"

    {:ok, run_t2} = Executions.start_run(run_t2)
    {:ok, _run_t2} = Executions.close_run(run_t2, status: "passed", outcome: "ok")
    closed = Repo.get!(GoalSession, session.id)
    assert closed.status == "passed"
    assert closed.finished_at != nil

    goal = Goals.get_goal(goal.id)
    assert goal.progress == 1.0
    assert goal.meta["progress_derived"] == true
  end

  test "P4: a failed run closes the session as failed and never touches task.status", %{
    ws: ws
  } do
    {:ok, goal} = new_goal(ws, "Failure", "failure-goal")
    {:ok, t1} = Tasks.create_task(%{"workspace_id" => ws.id, "title" => "Only step"})
    Tasks.link_to_goal(t1, goal)

    {:ok, session} = Executions.open_session(goal)
    [run] = runs_by_task(session, [t1.id])

    {:ok, run} = Executions.start_run(run)
    {:ok, _run} = Executions.close_run(run, status: "failed", outcome: "gate G2 fell")

    closed = Repo.get!(GoalSession, session.id)
    assert closed.status == "failed"
    assert closed.finished_at != nil

    # failed NO toca task.status (decisión 3).
    assert Repo.get!(Dran.Task, t1.id).status == "backlog"
  end

  test "P4: writeback is idempotent — a task already done with a passed run does not re-trigger",
       %{
         ws: ws
       } do
    {:ok, goal} = new_goal(ws, "Idempotent", "idempotent-goal")
    {:ok, t1} = Tasks.create_task(%{"workspace_id" => ws.id, "title" => "Step"})
    Tasks.link_to_goal(t1, goal)

    # Task ya está done ANTES de abrir la sesión.
    {:ok, _} = Tasks.update_task(t1, %{"status" => "done"})

    {:ok, session} = Executions.open_session(goal)
    [run] = runs_by_task(session, [t1.id])

    {:ok, run} = Executions.start_run(run)
    {:ok, closed_run} = Executions.close_run(run, status: "passed", outcome: "ok")

    assert closed_run.status == "passed"
    assert Repo.get!(Dran.Task, t1.id).status == "done"
    # El goal sigue derivado y en progreso (sin re-disparo).
    goal = Goals.get_goal(goal.id)
    assert goal.progress == 1.0
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Funciones extra de la API pública (retry, progress, guards)
  # ──────────────────────────────────────────────────────────────────────────

  test "retry_run creates a new attempt for the same (session, task) and keeps the failed one closed",
       %{
         ws: ws
       } do
    {:ok, goal} = new_goal(ws, "Retry", "retry-goal")
    {:ok, t1} = Tasks.create_task(%{"workspace_id" => ws.id, "title" => "Step"})
    Tasks.link_to_goal(t1, goal)

    {:ok, session} = Executions.open_session(goal)
    [run] = runs_by_task(session, [t1.id])

    {:ok, run} = Executions.start_run(run)
    {:ok, run} = Executions.close_run(run, status: "failed", outcome: "flaky")

    {:ok, retry} = Executions.retry_run(run)
    assert retry.session_id == run.session_id
    assert retry.task_id == run.task_id
    assert retry.attempt == 2
    assert retry.status == "pending"

    runs = Executions.list_runs(session)
    assert length(runs) == 2
    assert Enum.count(runs, &(&1.status == "failed")) == 1
    assert Enum.count(runs, &(&1.status == "pending")) == 1
  end

  test "session_progress counts runs by status and retries count too", %{ws: ws} do
    {:ok, goal} = new_goal(ws, "Progress", "progress-goal")
    {:ok, t1} = Tasks.create_task(%{"workspace_id" => ws.id, "title" => "Step"})
    Tasks.link_to_goal(t1, goal)

    {:ok, session} = Executions.open_session(goal)

    assert Executions.session_progress(session) == %{
             total: 1,
             pending: 1,
             in_flight: 0,
             passed: 0,
             failed: 0,
             skipped: 0
           }

    [run] = runs_by_task(session, [t1.id])
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
    assert Repo.get!(Dran.Task, t1.id).status == "done"
  end

  test "open_session with actor_id records the driver; label and context are stored", %{ws: ws} do
    {:ok, goal} = new_goal(ws, "Actor session", "actor-session")
    {:ok, t1} = Tasks.create_task(%{"workspace_id" => ws.id, "title" => "Step"})
    Tasks.link_to_goal(t1, goal)

    {:ok, actor} =
      Dran.Actors.create_actor(%{
        "name" => "exec-agent-#{System.unique_integer([:positive])}",
        "kind" => "agent"
      })

    {:ok, session} =
      Executions.open_session(goal,
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

  test "invalid close status is rejected without side effects", %{ws: ws} do
    {:ok, goal} = new_goal(ws, "Bad close", "bad-close")
    {:ok, t1} = Tasks.create_task(%{"workspace_id" => ws.id, "title" => "Step"})
    Tasks.link_to_goal(t1, goal)

    {:ok, session} = Executions.open_session(goal)
    [run] = runs_by_task(session, [t1.id])
    {:ok, _} = Executions.start_run(run)

    assert {:error, :invalid_status} = Executions.close_run(run, status: "banana")
    assert Repo.get!(TaskRun, run.id).status == "in_flight"
    assert Repo.get!(GoalSession, session.id).status == "in_flight"
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Concurrency guards (review: MAJOR memoria vs BD)
  # ──────────────────────────────────────────────────────────────────────────

  test "start_run on a stale struct loses: only one claim wins", %{ws: ws} do
    {:ok, goal} = new_goal(ws, "Claim race", "claim-race")
    {:ok, t1} = Tasks.create_task(%{"workspace_id" => ws.id, "title" => "Step"})
    Tasks.link_to_goal(t1, goal)

    {:ok, session} = Executions.open_session(goal)
    [run] = runs_by_task(session, [t1.id])

    # Dos dispatchers sostienen el MISMO struct pending; el update
    # condicional (WHERE status='pending') deja pasar a uno solo.
    {:ok, claimed} = Executions.start_run(run)
    assert claimed.status == "in_flight"

    assert {:error, {:wrong_status, "in_flight", "pending"}} = Executions.start_run(run)
    assert Repo.get!(TaskRun, run.id).status == "in_flight"
  end

  test "close_run on a stale/pending run is rejected without side effects", %{ws: ws} do
    {:ok, goal} = new_goal(ws, "Close race", "close-race")
    {:ok, t1} = Tasks.create_task(%{"workspace_id" => ws.id, "title" => "Step"})
    Tasks.link_to_goal(t1, goal)

    {:ok, session} = Executions.open_session(goal)
    [run] = runs_by_task(session, [t1.id])

    # close_run sobre un run pending: {:error, :not_in_flight}, sin efectos.
    assert {:error, :not_in_flight} = Executions.close_run(run, status: "passed")
    assert Repo.get!(TaskRun, run.id).status == "pending"
    assert Repo.get!(GoalSession, session.id).status == "in_flight"

    # Doble cierre con el MISMO struct in_flight: el segundo pierde.
    {:ok, run} = Executions.start_run(run)
    {:ok, _} = Executions.close_run(run, status: "passed", outcome: "first")

    stale = %TaskRun{run | status: "in_flight"}

    assert {:error, :not_in_flight} =
             Executions.close_run(stale, status: "failed", outcome: "second")

    assert Repo.get!(TaskRun, run.id).status == "passed"
    assert Repo.get!(Dran.Task, t1.id).status == "done"
  end

  test "start_run on a closed session is rejected", %{ws: ws} do
    {:ok, goal} = new_goal(ws, "Closed session", "closed-session")
    {:ok, t1} = Tasks.create_task(%{"workspace_id" => ws.id, "title" => "Step"})
    Tasks.link_to_goal(t1, goal)

    {:ok, session} = Executions.open_session(goal)
    [run] = runs_by_task(session, [t1.id])
    {:ok, run} = Executions.start_run(run)
    {:ok, _} = Executions.close_run(run, status: "passed", outcome: "ok")

    # La sesión auto-cerró passed: un run pending fantasma no puede arrancar.
    # (Reopen a mano del status del run para simular un dispatcher tardío.)
    {:ok, session2} = Executions.open_session(goal, label: "second pass")
    [%TaskRun{} = run2] = runs_by_task(session2, [t1.id])
    {:ok, _} = Executions.abort_session(session2)

    stale = %TaskRun{run2 | status: "pending"}
    assert {:error, :session_closed} = Executions.start_run(stale)
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Retry semantics (review: BLOCKER attempt viejo + reopen transaccional)
  # ──────────────────────────────────────────────────────────────────────────

  test "retry of a superseded attempt is rejected and never corrupts a closed session", %{ws: ws} do
    {:ok, goal} = new_goal(ws, "Superseded", "superseded-goal")
    {:ok, t1} = Tasks.create_task(%{"workspace_id" => ws.id, "title" => "Step"})
    Tasks.link_to_goal(t1, goal)

    {:ok, session} = Executions.open_session(goal)
    [run] = runs_by_task(session, [t1.id])

    {:ok, run} = Executions.start_run(run)
    {:ok, failed_run} = Executions.close_run(run, status: "failed", outcome: "flaky")

    # La sesión auto-cerró failed. Retry legítimo: reabre y crea attempt 2.
    {:ok, retry} = Executions.retry_run(failed_run)
    assert retry.attempt == 2
    assert Repo.get!(GoalSession, session.id).status == "in_flight"

    {:ok, retry} = Executions.start_run(retry)
    {:ok, _} = Executions.close_run(retry, status: "passed", outcome: "ok")

    # La sesión cerró passed. Un retry del attempt 1 VIEJO (struct failed en
    # mano del caller): rechazado SIN reabrir ni corromper la sesión.
    closed = Repo.get!(GoalSession, session.id)
    assert closed.status == "passed"
    assert closed.finished_at != nil

    assert {:error, {:superseded, "passed"}} = Executions.retry_run(failed_run)
    still_closed = Repo.get!(GoalSession, session.id)
    assert still_closed.status == "passed"
    assert still_closed.finished_at == closed.finished_at
  end

  test "retry after a failed auto-close reopens the session (decision 6, happy path)", %{ws: ws} do
    {:ok, goal} = new_goal(ws, "Reopen", "reopen-goal")
    {:ok, t1} = Tasks.create_task(%{"workspace_id" => ws.id, "title" => "Step"})
    Tasks.link_to_goal(t1, goal)

    {:ok, session} = Executions.open_session(goal)
    [run] = runs_by_task(session, [t1.id])
    {:ok, run} = Executions.start_run(run)
    {:ok, run} = Executions.close_run(run, status: "failed", outcome: "gate rojo")

    # Auto-cierre failed.
    assert Repo.get!(GoalSession, session.id).status == "failed"

    {:ok, retry} = Executions.retry_run(run)
    assert retry.status == "pending"
    assert Repo.get!(GoalSession, session.id).status == "in_flight"
    assert Repo.get!(GoalSession, session.id).finished_at == nil
  end

  # ──────────────────────────────────────────────────────────────────────────
  # skipped branch + abort_session (review: MAJOR escape manual / MINOR cobertura)
  # ──────────────────────────────────────────────────────────────────────────

  test "P4: a skipped run does not touch task.status and still closes the session as passed", %{
    ws: ws
  } do
    {:ok, goal} = new_goal(ws, "Skip", "skip-goal")
    {:ok, t1} = Tasks.create_task(%{"workspace_id" => ws.id, "title" => "Do"})
    {:ok, t2} = Tasks.create_task(%{"workspace_id" => ws.id, "title" => "Skip me"})
    Tasks.link_to_goal(t1, goal)
    Tasks.link_to_goal(t2, goal)

    {:ok, session} = Executions.open_session(goal)
    [run_t1, run_t2] = runs_by_task(session, [t1.id, t2.id])

    {:ok, run_t1} = Executions.start_run(run_t1)
    {:ok, _} = Executions.close_run(run_t1, status: "passed", outcome: "ok")

    {:ok, run_t2} = Executions.start_run(run_t2)
    {:ok, _} = Executions.close_run(run_t2, status: "skipped", outcome: "fuera de alcance")

    # skipped NO escribe done en la task...
    assert Repo.get!(Dran.Task, t2.id).status == "backlog"
    # ...pero cuenta como cierre válido: sesión passed con finished_at.
    closed = Repo.get!(GoalSession, session.id)
    assert closed.status == "passed"
    assert closed.finished_at != nil
  end

  test "abort_session closes an open session as aborted, skips open runs and recomputes", %{
    ws: ws
  } do
    {:ok, goal} = new_goal(ws, "Abort", "abort-goal")
    {:ok, t1} = Tasks.create_task(%{"workspace_id" => ws.id, "title" => "Step 1"})
    {:ok, t2} = Tasks.create_task(%{"workspace_id" => ws.id, "title" => "Step 2"})
    Tasks.link_to_goal(t1, goal)
    Tasks.link_to_goal(t2, goal)

    {:ok, session} = Executions.open_session(goal)
    [run_t1, _run_t2] = runs_by_task(session, [t1.id, t2.id])
    {:ok, run_t1} = Executions.start_run(run_t1)
    {:ok, _} = Executions.close_run(run_t1, status: "passed", outcome: "ok")

    {:ok, aborted} = Executions.abort_session(Repo.get!(GoalSession, session.id))
    assert aborted.status == "aborted"
    assert aborted.finished_at != nil

    # El run pending restante quedó skipped con outcome de abort.
    runs = Executions.list_runs(session)
    skipped = Enum.find(runs, &(&1.status == "skipped"))
    assert skipped.outcome == "session aborted"

    # Las tasks no se tocan (skipped no escribe board).
    assert Repo.get!(Dran.Task, t2.id).status == "backlog"

    # Abortar una sesión cerrada: rechazado.
    assert {:error, :session_closed} =
             Executions.abort_session(Repo.get!(GoalSession, session.id))
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Cross-goal prereqs (review: MAJOR deadlock de sesión)
  # ──────────────────────────────────────────────────────────────────────────

  test "a cross-goal prereq without a run in the session falls back to board status", %{ws: ws} do
    {:ok, goal_a} = new_goal(ws, "Goal A", "goal-a")
    {:ok, goal_b} = new_goal(ws, "Goal B", "goal-b")
    {:ok, external} = Tasks.create_task(%{"workspace_id" => ws.id, "title" => "External prereq"})
    {:ok, step} = Tasks.create_task(%{"workspace_id" => ws.id, "title" => "Step A"})

    Tasks.link_to_goal(external, goal_b)
    Tasks.link_to_goal(step, goal_a)
    {:ok, _} = Contracts.add_dependency(step, external)

    {:ok, session} = Executions.open_session(goal_a)
    [run_step] = runs_by_task(session, [step.id])

    # El prereq externo NO tiene run en la sesión y su task está backlog:
    # el paso no está listo.
    refute Executions.run_ready?(run_step)

    # La task externa se completa en el BOARD (goal B, sin sesión): el paso
    # de la sesión A queda habilitado — mismo modelo global que dependency_states.
    {:ok, _} = Tasks.update_task(external, %{"status" => "done"})
    assert Executions.run_ready?(run_step)
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Snapshot de contrato (review: MINOR caso positivo)
  # ──────────────────────────────────────────────────────────────────────────

  test "contract_version snapshots the contract at open time and stays frozen", %{ws: ws} do
    {:ok, goal} = new_goal(ws, "Contract", "contract-goal")

    contract = %{
      "intent" => "Ship the login flow",
      "claims" => [%{"id" => "P1", "text" => "form validates", "verify" => "mix test"}],
      "gates" => [%{"id" => "G1", "cmd" => "mix test"}]
    }

    {:ok, t1} =
      Tasks.create_task(%{
        "workspace_id" => ws.id,
        "title" => "Contracted step",
        "meta" => %{"contract" => contract}
      })

    Tasks.link_to_goal(t1, goal)

    {:ok, session} = Executions.open_session(goal)
    [run] = runs_by_task(session, [t1.id])
    assert run.contract_version == contract

    # La task muta su contrato DESPUÉS de abrir: el run conserva el snapshot.
    mutated = put_in(contract, ["intent"], "Changed intent")
    task = Repo.get!(Dran.Task, t1.id)
    {:ok, _} = Tasks.update_task(task, %{"meta" => Map.put(task.meta, "contract", mutated)})

    assert Repo.get!(TaskRun, run.id).contract_version == contract
  end

  defp new_goal(ws, title, slug) do
    Goals.create_goal(%{"workspace_id" => ws.id, "title" => title, "slug" => slug})
  end

  defp runs_by_task(session, task_ids) do
    runs = Executions.list_runs(session)
    Enum.map(task_ids, fn task_id -> Enum.find(runs, &(&1.task_id == task_id)) end)
  end
end
