defmodule DranWeb.TaskBoardLiveTest do
  @moduledoc """
  Gate W4c (P15): el board global filtra por goal y SOLO muestra goals que el
  lector puede leer; el board de un goal ajeno privado no se abre (navega
  fuera). Mover una task desde la UI cambia de columna y el progreso derivado
  del goal se refleja — nunca se guarda.

  El detalle del goal muestra el progreso derivado y sus subgoals legibles.
  """
  use DranWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Dran.{Accounts, Goals, Tasks}

  defp editor!(label) do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.create_user(%{
        email: "#{label}-#{unique}@dran.test",
        api_token: "tok-#{label}-#{unique}"
      })

    user
  end

  # Un lector no-owner: `instance_role` default "editor" se resuelve como
  # `{:reader, id}` — el lector personal ordinario.
  defp login(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:user, user.email)
    |> Plug.Conn.put_session(:is_owner, false)
    |> Plug.Conn.put_session(:workspace_slug, "personal")
  end

  # Un ADMIN. Lo que manda es la fila `users.is_owner`: el hook la lee de la
  # base, nunca de la cookie (`Auth.assign_to_socket/3`).
  defp owner!(label) do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.create_user(%{
        email: "owner-#{label}-#{unique}@dran.test",
        api_token: "tok-owner-#{label}-#{unique}",
        is_owner: true
      })

    user
  end

  defp goal!(owner, attrs) do
    {:ok, goal} =
      Goals.create_goal(
        Map.merge(
          %{"title" => "Goal #{System.unique_integer([:positive])}", "owner_user_id" => owner.id},
          attrs
        )
      )

    goal
  end

  test "el board global solo muestra las tasks de goals que el lector puede leer" do
    author = editor!("author")
    stranger = editor!("stranger")

    mine = goal!(author, %{"title" => "Mi meta"})
    {:ok, mine_task} = Tasks.create_task(%{"goal_id" => mine.id, "title" => "Visible"})

    theirs = goal!(stranger, %{"title" => "Meta ajena"})
    {:ok, their_task} = Tasks.create_task(%{"goal_id" => theirs.id, "title" => "Secreta"})

    {:ok, view, _html} = live(login(build_conn(), author), ~p"/tasks")

    assert has_element?(view, "#task-card-#{mine_task.id}")
    refute has_element?(view, "#task-card-#{their_task.id}")

    # El filtro por goal solo ofrece lo legible.
    assert has_element?(view, "#board-goal-filter-select option[value='#{mine.id}']")
    refute has_element?(view, "#board-goal-filter-select option[value='#{theirs.id}']")
  end

  test "el board de un goal ajeno privado no se abre: navega fuera" do
    author = editor!("author2")
    stranger = editor!("stranger2")

    theirs = goal!(stranger, %{"title" => "Privada ajena"})

    assert {:error, {:live_redirect, %{to: "/tasks"}}} =
             live(login(build_conn(), author), ~p"/tasks/#{theirs.id}")
  end

  test "el board de un goal propio se abre y muestra sus tasks" do
    author = editor!("author3")
    goal = goal!(author, %{"title" => "Mi board"})
    {:ok, task} = Tasks.create_task(%{"goal_id" => goal.id, "title" => "En mi board"})

    {:ok, view, html} = live(login(build_conn(), author), ~p"/tasks/#{goal.id}")

    assert html =~ "Mi board"
    assert has_element?(view, "#task-card-#{task.id}")
    assert has_element?(view, "#board-all-tasks")
  end

  test "mover una task desde la UI cambia de columna y el progreso derivado se refleja" do
    author = editor!("author4")
    goal = goal!(author, %{"title" => "Con progreso"})
    {:ok, task} = Tasks.create_task(%{"goal_id" => goal.id, "title" => "Mover"})

    {:ok, view, _html} = live(login(build_conn(), author), ~p"/tasks")

    assert has_element?(view, "#column-backlog #task-card-#{task.id}")
    refute has_element?(view, "#column-done #task-card-#{task.id}")

    # Mover es drag & drop: la tarjeta se arrastra y el select de estado ya no
    # existe en la tarjeta.
    assert has_element?(view, "#task-card-#{task.id}[draggable='true']")
    refute has_element?(view, "#task-move-select-#{task.id}")

    # El hook colocado empuja `move` — el MISMO evento que antes servía el
    # select, así el servidor no cambia de puerta.
    view
    |> element("#board-columns")
    |> render_hook("move", %{"task_id" => task.id, "status" => "done"})

    assert has_element?(view, "#column-done #task-card-#{task.id}")
    refute has_element?(view, "#column-backlog #task-card-#{task.id}")

    # El progreso es DERIVADO de las tasks: mover a done lo refleja.
    assert Goals.progress(goal).done == 1
    assert Goals.progress(goal).total == 1

    # Y el detalle del goal lo muestra.
    {:ok, goal_view, _ghtml} = live(login(build_conn(), author), ~p"/goals/#{goal.id}")
    assert has_element?(goal_view, "#goal-progress[data-done='1'][data-total='1']")
  end

  test "el detalle del goal lista sus subgoals legibles" do
    author = editor!("author5")
    parent = goal!(author, %{"title" => "Padre"})
    child = goal!(author, %{"title" => "Hijo", "parent_goal_id" => parent.id})

    {:ok, view, _html} = live(login(build_conn(), author), ~p"/goals/#{parent.id}")

    assert has_element?(view, "#goal-child-#{child.id}")
  end

  # ── Filtros (contrato de paridad UI/UX) ───────────────────────────────────

  describe "filtros del board" do
    test "los tres filtros existen y su estado vive en la URL" do
      author = editor!("f1")
      goal = goal!(author, %{"title" => "Filtrable"})

      {:ok, view, _html} = live(login(build_conn(), author), ~p"/tasks")

      assert has_element?(view, "#board-filters")
      assert has_element?(view, "#board-goal-filter-select")
      assert has_element?(view, "#board-status-filter")
      # El filtro por responsable es de ADMIN: un no-owner no ve el control.
      refute has_element?(view, "#board-assignee-filter")

      # El form de un no-owner no tiene campo de responsable: el patch lleva
      # sólo goal + estado (el orden de la query es fijo y estable).
      view
      |> form("#board-filters", %{
        "goal_id" => goal.id,
        "status" => "done"
      })
      |> render_change()

      assert_patch(view, ~p"/tasks?goal_id=#{goal.id}&status=done")
    end

    test "filtrar por estado deja sólo esa columna con tarjetas" do
      author = editor!("f2")
      goal = goal!(author, %{"title" => "Estados"})
      {:ok, todo} = Tasks.create_task(%{"goal_id" => goal.id, "title" => "Pendiente"})

      {:ok, done} =
        Tasks.create_task(%{"goal_id" => goal.id, "title" => "Hecha", "status" => "done"})

      {:ok, view, _html} = live(login(build_conn(), author), ~p"/tasks?status=done")

      assert has_element?(view, "#column-done #task-card-#{done.id}")
      refute has_element?(view, "#task-card-#{todo.id}")
      # Las columnas siguen ahí: el filtro recorta, no esconde el tablero.
      assert has_element?(view, "#column-backlog")
    end

    test "un no-owner no ve el filtro por responsable ni lo aplica por query string" do
      author = editor!("f3")
      goal = goal!(author, %{"title" => "Responsables"})

      {:ok, mine} =
        Tasks.create_task(%{
          "goal_id" => goal.id,
          "title" => "Mía",
          "assignee_id" => author.id
        })

      {:ok, theirs} = Tasks.create_task(%{"goal_id" => goal.id, "title" => "Sin dueño"})

      # El `?assignee_id=` de un no-owner se ignora (`filters_from/2`): no queda
      # un filtro aplicado sin control que lo explique.
      {:ok, view, _html} = live(login(build_conn(), author), ~p"/tasks?assignee_id=#{author.id}")

      refute has_element?(view, "#board-assignee-filter")
      assert has_element?(view, "#task-card-#{mine.id}")
      assert has_element?(view, "#task-card-#{theirs.id}")
    end

    test "el admin sí filtra por responsable y el select ofrece a las personas" do
      admin = owner!("f3b")
      other = editor!("f3c")
      goal = goal!(admin, %{"title" => "Responsables del admin"})

      {:ok, mine} =
        Tasks.create_task(%{
          "goal_id" => goal.id,
          "title" => "Mía",
          "assignee_id" => admin.id
        })

      {:ok, theirs} = Tasks.create_task(%{"goal_id" => goal.id, "title" => "Sin dueño"})

      {:ok, view, _html} = live(login(build_conn(), admin), ~p"/tasks?assignee_id=#{admin.id}")

      # El select ofrece a las personas, no una lista escrita a mano.
      assert has_element?(view, "#board-assignee-filter option[value='#{admin.id}']")
      assert has_element?(view, "#board-assignee-filter option[value='#{other.id}']")

      assert has_element?(view, "#task-card-#{mine.id}")
      refute has_element?(view, "#task-card-#{theirs.id}")
    end

    test "filtrar por goal recorta a ese goal y sobrevive al reload" do
      author = editor!("f4")
      a = goal!(author, %{"title" => "Goal A"})
      b = goal!(author, %{"title" => "Goal B"})
      {:ok, ta} = Tasks.create_task(%{"goal_id" => a.id, "title" => "De A"})
      {:ok, tb} = Tasks.create_task(%{"goal_id" => b.id, "title" => "De B"})

      {:ok, view, _html} = live(login(build_conn(), author), ~p"/tasks?goal_id=#{a.id}")

      assert has_element?(view, "#task-card-#{ta.id}")
      refute has_element?(view, "#task-card-#{tb.id}")
      assert has_element?(view, "#board-goal-filter-select option[value='#{a.id}'][selected]")
    end
  end

  # ── Alta por modal con selector de goal ───────────────────────────────────

  describe "alta por modal" do
    test "el CTA abre el modal de pages con el selector de goal" do
      author = editor!("m1")
      goal = goal!(author, %{"title" => "Destino"})

      {:ok, view, _html} = live(login(build_conn(), author), ~p"/tasks")

      refute has_element?(view, "#task-resource-modal")

      view |> element("#task-new") |> render_click()

      assert_patch(view, ~p"/tasks?new=true")
      assert has_element?(view, "#task-resource-modal")
      assert has_element?(view, "#task-resource-modal #task-form")
      # El cuerpo: el mismo editor markdown (task[body]).
      assert has_element?(view, "#task-editor")
      assert has_element?(view, "#task-form input[name='task[body]']")
      assert has_element?(view, "#task-goal-select option[value='#{goal.id}']")
    end

    test "la task nace en el goal ELEGIDO en el selector" do
      author = editor!("m2")
      a = goal!(author, %{"title" => "Elegido"})
      b = goal!(author, %{"title" => "Otro"})

      {:ok, view, _html} = live(login(build_conn(), author), ~p"/tasks?new=true")

      view
      |> form("#task-form", %{
        "task" => %{"title" => "Con goal elegido", "goal_id" => b.id, "status" => "todo"}
      })
      |> render_submit()

      assert_patch(view, ~p"/tasks")

      [task] = Tasks.list_tasks_for_goal(b)
      assert task.title == "Con goal elegido"
      assert task.status == "todo"
      assert Tasks.list_tasks_for_goal(a) == []
      assert has_element?(view, "#task-card-#{task.id}")
    end

    test "sin elegir goal el default es el goal del FILTRO" do
      author = editor!("m3")
      goal = goal!(author, %{"title" => "Filtrado"})

      {:ok, view, _html} = live(login(build_conn(), author), ~p"/tasks?goal_id=#{goal.id}")

      view |> element("#task-new") |> render_click()
      assert_patch(view, ~p"/tasks?goal_id=#{goal.id}&new=true")

      view |> form("#task-form", %{"task" => %{"title" => "Cae en el filtro"}}) |> render_submit()

      [task] = Tasks.list_tasks_for_goal(goal)
      assert task.title == "Cae en el filtro"
      # El estado nace del default del schema, no de una columna de origen.
      assert task.status == "backlog"
    end

    test "sin filtro ni tablero, la task cae en la bandeja del dueño" do
      author = editor!("m4")

      {:ok, view, _html} = live(login(build_conn(), author), ~p"/tasks?new=true")

      view |> form("#task-form", %{"task" => %{"title" => "Captura"}}) |> render_submit()

      {:ok, inbox} = Goals.ensure_inbox(author)
      [task] = Tasks.list_tasks_for_goal(inbox)
      assert task.title == "Captura"
    end

    test "el board de un goal crea en ESE goal sin tocar el selector" do
      author = editor!("m5")
      goal = goal!(author, %{"title" => "Mi tablero"})

      {:ok, view, _html} = live(login(build_conn(), author), ~p"/tasks/#{goal.id}?new=true")

      view
      |> form("#task-form", %{"task" => %{"title" => "Directa", "status" => "in_progress"}})
      |> render_submit()

      assert_patch(view, ~p"/tasks/#{goal.id}")
      [task] = Tasks.list_tasks_for_goal(goal)
      assert task.status == "in_progress"
    end

    test "el estado del alta sale del filtro activo" do
      author = editor!("m6")

      {:ok, view, _html} = live(login(build_conn(), author), ~p"/tasks?status=done&new=true")

      view |> form("#task-form", %{"task" => %{"title" => "Nace hecha"}}) |> render_submit()

      {:ok, inbox} = Goals.ensure_inbox(author)
      [task] = Tasks.list_tasks_for_goal(inbox, status: "done")
      assert task.title == "Nace hecha"
    end

    test "el selector y el alta NO ofrecen ni aceptan un goal ajeno privado" do
      author = editor!("m7")
      stranger = editor!("m7b")
      theirs = goal!(stranger, %{"title" => "Ajena"})

      {:ok, view, _html} = live(login(build_conn(), author), ~p"/tasks?new=true")

      refute has_element?(view, "#task-goal-select option[value='#{theirs.id}']")

      # Un cliente hostil manda el id igual: no se crea nada y la fila no aparece.
      before = Dran.Repo.aggregate(Tasks.Task, :count, :id)

      # `form/3` rechaza un valor que no está en las opciones: un cliente hostil
      # despacha el evento con el id igual (el fallo cerrado es del servidor).
      render_submit(view, "create_task", %{
        "task" => %{"title" => "Colada", "goal_id" => theirs.id}
      })

      assert Dran.Repo.aggregate(Tasks.Task, :count, :id) == before
      assert render(view) =~ "not available"
      refute has_element?(view, "#task-card-#{theirs.id}")
    end

    test "cerrar el modal vuelve al board con un patch" do
      author = editor!("m8")

      {:ok, view, _html} = live(login(build_conn(), author), ~p"/tasks?new=true")
      assert has_element?(view, "#task-resource-modal")

      render_click(view, "close_task_modal")

      assert_patch(view, ~p"/tasks")
      refute has_element?(view, "#task-resource-modal")
    end
  end

  # ── Editar SIEMPRE en modal (nunca un form dentro de la tarjeta) ───────────

  describe "editar una task" do
    test "el Edit abre el modal, guarda desde ahí y se cierra" do
      author = editor!("e1")
      goal = goal!(author, %{"title" => "Editable"})
      {:ok, task} = Tasks.create_task(%{"goal_id" => goal.id, "title" => "Antes"})

      {:ok, view, _html} = live(login(build_conn(), author), ~p"/tasks")

      # La tarjeta no expande ningún form: hasta el click no hay modal.
      refute has_element?(view, "#task-edit-form-#{task.id}")
      refute has_element?(view, "#task-edit-modal")

      view |> element("#task-edit-#{task.id}") |> render_click()

      assert has_element?(view, "#task-edit-modal")
      assert has_element?(view, "#task-edit-modal #task-edit-form-#{task.id}")
      assert has_element?(view, "#task-edit-#{task.id}-title[value='Antes']")

      # Los campos son los MISMOS que en el detalle del goal (un solo modal para
      # las dos superficies): título, cuerpo, estado, prioridad, fecha y pasos.
      for field <- ~w(title editor status priority due checklist) do
        assert has_element?(view, "#task-edit-#{task.id}-#{field}")
      end

      # El cuerpo viaja como task[body]: el editor markdown de la casa.
      assert has_element?(view, "#task-edit-#{task.id}-editor")
      assert has_element?(view, "#task-edit-form-#{task.id} input[name='task[body]']")

      view
      |> form("#task-edit-form-#{task.id}",
        task: %{"title" => "Después"},
        task_id: task.id,
        lock_version: task.lock_version
      )
      |> render_submit()

      assert Dran.Repo.get!(Tasks.Task, task.id).title == "Después"
      # Guardar cierra el modal.
      refute has_element?(view, "#task-edit-modal")

      # El estado también se cambia desde acá (antes sólo se arrastraba): se
      # escribe por la única puerta (`Tasks.move_task/2`) y la columna lo sigue.
      view |> element("#task-edit-#{task.id}") |> render_click()

      view
      |> form("#task-edit-form-#{task.id}",
        task: %{"title" => "Después", "status" => "in_progress"},
        task_id: task.id,
        lock_version: Dran.Repo.get!(Tasks.Task, task.id).lock_version
      )
      |> render_submit()

      assert Dran.Repo.get!(Tasks.Task, task.id).status == "in_progress"
      assert has_element?(view, "#column-in_progress #task-card-#{task.id}")

      # Volver a abrirlo y cerrarlo sin guardar también lo cierra.
      view |> element("#task-edit-#{task.id}") |> render_click()
      assert has_element?(view, "#task-edit-modal")

      render_click(view, "close_edit_modal")
      refute has_element?(view, "#task-edit-modal")
    end

    test "borrar la task desde su modal (botón del molde compartido)" do
      author = editor!("e2")
      goal = goal!(author, %{"title" => "Con basura"})
      {:ok, task} = Tasks.create_task(%{"goal_id" => goal.id, "title" => "Sobra"})

      {:ok, view, _html} = live(login(build_conn(), author), ~p"/tasks")

      view |> element("#task-edit-#{task.id}") |> render_click()
      assert has_element?(view, "#task-edit-modal #task-edit-#{task.id}-delete")

      view |> element("#task-edit-#{task.id}-delete") |> render_click()

      refute Dran.Repo.get(Tasks.Task, task.id)
      refute has_element?(view, "#task-card-#{task.id}")
      refute has_element?(view, "#task-edit-modal")
    end
  end
end
