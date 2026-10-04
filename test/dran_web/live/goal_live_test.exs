defmodule DranWeb.GoalLiveTest do
  @moduledoc """
  Gate W4 (contrato de superficies): la web crea y administra goals y tasks.

  - P12: crear, editar y borrar desde la UI sella al AUTOR como dueño (nunca el
    formulario) y deja lo privado invisible a un tercero — ni por URL;
  - Constraint 4: una sesión sin fila en `users` navega fuera (fail-closed);
  - Constraint 9: la task creada desde el detalle nace en ESE goal, y el
    progreso derivado se refleja sin guardarse.
  """

  use DranWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Dran.{Accounts, Goals, Knowledge, Related, Tasks}

  import Ecto.Query, only: [from: 2]

  setup do
    Dran.DataCase.ensure_workspace!()
    u = System.unique_integer([:positive])

    {:ok, author} =
      Accounts.create_user(%{
        email: "goal-live-author-#{u}@example.com",
        name: "Author",
        api_token: "tok-live-author-#{u}"
      })

    {:ok, stranger} =
      Accounts.create_user(%{
        email: "goal-live-stranger-#{u}@example.com",
        name: "Stranger",
        api_token: "tok-live-stranger-#{u}"
      })

    %{author: author, stranger: stranger}
  end

  describe "crear (P12)" do
    test "el formulario sella al autor como dueño y privado", %{author: author, conn: conn} do
      {:ok, view, _html} = live(login(conn, author), ~p"/goals?new=true")

      view
      |> form("#goal-form",
        goal: %{"title" => "Lanzamiento", "status" => "active", "visibility" => "private"}
      )
      |> render_submit()

      goal = only_goal(author)
      assert_redirect(view, ~p"/goals/#{goal.id}")
      assert goal.title == "Lanzamiento"
      assert goal.owner_user_id == author.id
      assert goal.visibility == "private"
    end

    test "el dueño del formulario NO puede elegir el dueño", %{author: author, conn: conn} do
      {:ok, view, _html} = live(login(conn, author), ~p"/goals?new=true")

      # Un cliente hostil manda el dueño por el evento (no hay input para él):
      # el sello server-side lo pisa.
      render_submit(view, "save_goal", %{
        "goal" => %{"title" => "Mío", "owner_user_id" => "999999"}
      })

      assert only_goal(author).owner_user_id == author.id
    end

    test "la lista muestra el goal nuevo y su tarjeta abre el detalle", %{
      author: author,
      conn: conn
    } do
      goal = goal!(author, %{"title" => "Visible"})

      {:ok, view, _html} = live(login(conn, author), ~p"/goals")

      assert has_element?(view, "#goal-card-#{goal.id}")
      assert has_element?(view, "#goal-new")
    end
  end

  describe "editar y borrar (P12)" do
    test "editar cambia el título y vuelve al detalle EN la página", %{author: author, conn: conn} do
      goal = goal!(author, %{"title" => "Antes"})

      # La edición es `?edit=true` sobre el MISMO LiveView del detalle: no hay
      # ruta /edit y el guardado sale del modo edición con un patch.
      {:ok, view, _html} = live(login(conn, author), ~p"/goals/#{goal.id}?edit=true")

      assert has_element?(view, "#goal-edit-panel")

      view
      |> form("#goal-form", goal: %{"title" => "Después"})
      |> render_submit()

      assert_patch(view, ~p"/goals/#{goal.id}")
      assert Dran.Repo.get!(Goals.Goal, goal.id).title == "Después"
    end

    test "borrar se lleva el goal y sus tasks", %{author: author, conn: conn} do
      goal = goal!(author, %{"title" => "Borrable"})
      {:ok, task} = Tasks.create_task(%{"goal_id" => goal.id, "title" => "Suya"})

      {:ok, view, _html} = live(login(conn, author), ~p"/goals/#{goal.id}")

      view |> element("#goal-delete") |> render_click()

      assert_redirect(view, ~p"/goals")
      assert Dran.Repo.get(Goals.Goal, goal.id) == nil
      assert Dran.Repo.get(Tasks.Task, task.id) == nil
    end
  end

  describe "aislamiento (P12)" do
    test "un goal ajeno privado no se abre ni por URL", %{author: author, stranger: stranger} do
      goal = goal!(author, %{"title" => "Privado"})

      assert {:error, {:live_redirect, %{to: "/goals"}}} =
               live(login(build_conn(), stranger), ~p"/goals/#{goal.id}")

      assert {:error, {:live_redirect, %{to: "/goals"}}} =
               live(login(build_conn(), stranger), ~p"/goals/#{goal.slug}")
    end

    test "el tercero no ve el goal en la lista", %{author: author, stranger: stranger} do
      goal = goal!(author, %{"title" => "Ajeno"})

      {:ok, view, _html} = live(login(build_conn(), stranger), ~p"/goals")

      refute has_element?(view, "#goal-card-#{goal.id}")
    end

    test "una sesión sin fila en users navega fuera (fail-closed)", %{conn: conn} do
      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session(:user, "ghost@no.row")
        |> Plug.Conn.put_session(:workspace_slug, "personal")

      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/goals")
      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/goals?new=true")
    end
  end

  describe "tasks desde el detalle" do
    test "la task nace en ESE goal y el progreso derivado se refleja", %{
      author: author,
      conn: conn
    } do
      goal = goal!(author, %{"title" => "Con tasks"})

      {:ok, view, _html} = live(login(conn, author), ~p"/goals/#{goal.id}")

      assert has_element?(view, "#goal-progress[data-total='0']")

      # El alta es un MODAL por estado de URL (el mismo molde de pages), con
      # más detalle que la cajita vieja.
      view |> element("#goal-task-new") |> render_click()
      assert_patch(view, ~p"/goals/#{goal.id}?new_task=true")
      assert has_element?(view, "#task-resource-modal")
      assert has_element?(view, "#goal-task-status")
      assert has_element?(view, "#goal-task-priority")
      # El cuerpo: el editor markdown compartido (el mismo de goals y plans).
      assert has_element?(view, "#goal-task-editor")
      assert has_element?(view, "#goal-task-form input[name='task[body]']")

      view
      |> form("#goal-task-form", task: %{"title" => "Comprar pan"})
      |> render_submit()

      assert_patch(view, ~p"/goals/#{goal.id}")
      refute has_element?(view, "#task-resource-modal")

      assert has_element?(view, "#goal-progress[data-total='1']")
      assert render(view) =~ "Comprar pan"

      [task] = Tasks.list_tasks_for_goal(goal)
      assert task.title == "Comprar pan"
      assert task.goal_id == goal.id
    end

    test "el detalle lista las tasks del goal con su estado", %{author: author, conn: conn} do
      goal = goal!(author, %{"title" => "Con tasks"})

      {:ok, task} =
        Tasks.create_task(%{"goal_id" => goal.id, "title" => "Una", "status" => "done"})

      {:ok, view, _html} = live(login(conn, author), ~p"/goals/#{goal.id}")

      assert has_element?(view, "#tasks-#{task.id}[data-status='done']")
      assert has_element?(view, "#goal-progress[data-done='1']")
    end
  end

  describe "la estructura de pages (modal y edición en página)" do
    test "el CTA abre el alta en un modal con ?new=true, no navegando", %{
      author: author,
      conn: conn
    } do
      {:ok, view, _html} = live(login(conn, author), ~p"/goals")

      refute has_element?(view, "#goal-resource-modal")

      view |> element("#goal-new") |> render_click()

      assert_patch(view, ~p"/goals?new=true")
      assert has_element?(view, "#goal-resource-modal")
      assert has_element?(view, "#goal-resource-modal #goal-form")
      # El body se edita con el editor de markdown de pages, no con un textarea.
      assert has_element?(view, "#goal-editor[phx-hook='MarkdownEditor']")
    end

    test "cerrar el modal vuelve a la lista con un patch (el stream sobrevive)", %{
      author: author,
      conn: conn
    } do
      goal!(author, %{"title" => "Visible"})

      {:ok, view, _html} = live(login(conn, author), ~p"/goals?new=true")
      assert has_element?(view, "#goal-resource-modal")

      render_click(view, "close_goal_modal")

      assert_patch(view, ~p"/goals")
      refute has_element?(view, "#goal-resource-modal")
      assert has_element?(view, "#goal-card-#{only_goal(author).id}")
    end

    test "el detalle alterna Edit y View con ?edit=true", %{author: author, conn: conn} do
      goal = goal!(author, %{"title" => "Con panel"})

      {:ok, view, _html} = live(login(conn, author), ~p"/goals/#{goal.id}")
      assert has_element?(view, "#goal-edit")
      refute has_element?(view, "#goal-edit-panel")

      view |> element("#goal-edit") |> render_click()

      assert_patch(view, ~p"/goals/#{goal.id}?edit=true")
      assert has_element?(view, "#goal-edit-panel")
      assert has_element?(view, "#goal-view")

      view |> element("#goal-view") |> render_click()

      assert_patch(view, ~p"/goals/#{goal.id}")
      refute has_element?(view, "#goal-edit-panel")
      assert has_element?(view, "#goal-progress")
    end
  end

  # El estándar de la LISTA (contrato de paridad UI/UX, W5): header con CTA,
  # estado vacío con icono+copy+CTA y tarjeta `surface-2 lift` en columna.
  describe "el estándar de la lista (pages)" do
    test "sin goals el índice muestra el estado vacío estándar y su CTA", %{
      author: author,
      conn: conn
    } do
      {:ok, view, _html} = live(login(conn, author), ~p"/goals")

      assert has_element?(view, "[data-testid='empty-state']")
      assert has_element?(view, "[data-testid='empty-state'] h3", "No goals yet")
      assert has_element?(view, "[data-testid='empty-state'] a[href='/goals?new=true']")
      assert has_element?(view, "[data-testid='new-goal-button']")
      # El contenedor del stream sigue montado: los inserts no se pierden.
      assert has_element?(view, "#goals[phx-update='stream']")
    end

    test "con goals el vacío desaparece y la tarjeta es la estándar", %{
      author: author,
      conn: conn
    } do
      goal = goal!(author, %{"title" => "Estándar", "summary" => "Con resumen"})

      {:ok, view, _html} = live(login(conn, author), ~p"/goals")

      refute has_element?(view, "[data-testid='empty-state']")
      assert has_element?(view, "[data-testid='goal-card-#{goal.id}']")
      assert has_element?(view, "#goal-card-#{goal.id}.surface-2.lift")
      assert has_element?(view, "#goal-card-#{goal.id} .size-8")
      assert has_element?(view, "#goal-card-#{goal.id} a[href='/goals/#{goal.id}']")
      assert render(view) =~ "Con resumen"
      # La lista es una columna, no una grilla propia.
      assert has_element?(view, "#goals.space-y-2")
      refute has_element?(view, "#goals.grid")
    end
  end

  # El destino (scope) es UNO: mismo control que pages, píldora traducida que
  # se oculta en privado, y el botón de compartir para el dueño.
  describe "el destino (scope) es el estándar" do
    test "el alta declara el destino con el control compartido", %{author: author, conn: conn} do
      {:ok, view, _html} = live(login(conn, author), ~p"/goals?new=true")

      assert has_element?(view, "#goal-visibility-picker")

      # El control vive en el HEADER del modal, junto a la ✕ (no en el form del
      # body): sus radios lo apuntan con el atributo HTML `form`, que es lo que
      # los hace viajar en el submit.
      assert has_element?(view, "#goal-resource-modal-header-actions #goal-visibility-picker")
      refute has_element?(view, "#goal-form #goal-visibility-picker")

      assert has_element?(
               view,
               "#goal-resource-modal-header-actions input[name='goal[visibility]'][form='goal-form']"
             )

      # UN input por nivel, DENTRO de su label: el click marca el radio y el CSS
      # pinta el pill activo (has-[:checked]) — sin JS y sin round-trip.
      for level <- ~w(private public shared) do
        assert has_element?(view, "#goal-visibility-picker label input[value='#{level}']")
      end

      # Y ninguno de más: el input hidden duplicado (el doble valor viejo) murió.
      refute has_element?(view, "#goal-visibility-picker input[type='hidden']")

      assert has_element?(view, "input[name='goal[visibility]'][value='private']")
      assert has_element?(view, "#goal_visibility-private")
      assert has_element?(view, "#goal_visibility-public")
      assert has_element?(view, "#goal_visibility-shared")

      # Y el nivel elegido viaja y SE GUARDA: el pill no era sólo decorativo.
      view
      |> form("#goal-form", %{"goal" => %{"title" => "Publico elegido", "visibility" => "public"}})
      |> render_submit()

      assert only_goal(author).visibility == "public"
    end

    test "la píldora traduce el destino y se oculta en privado", %{author: author, conn: conn} do
      goal = goal!(author, %{"title" => "Privado"})

      {:ok, view, _html} = live(login(conn, author), ~p"/goals/#{goal.id}")
      # El default no se anuncia y el valor crudo nunca se imprime.
      refute has_element?(view, "#goal-visibility-badge")
      refute render(view) =~ ">private<"

      {:ok, pub} = Dran.Goals.update_goal(goal, %{"visibility" => "public"})

      {:ok, view, _html} = live(login(conn, author), ~p"/goals/#{pub.id}")
      assert has_element?(view, "#goal-visibility-badge", t("Public"))
    end

    test "el dueño puede compartir aunque el goal siga privado", %{author: author, conn: conn} do
      goal = goal!(author, %{"title" => "Compartible"})

      {:ok, view, _html} = live(login(conn, author), ~p"/goals/#{goal.id}")

      assert has_element?(view, "#goal-share")
    end

    test "un tercero con acceso no administra el destino", %{author: author, stranger: stranger} do
      goal = goal!(author, %{"title" => "Público", "visibility" => "public"})

      {:ok, view, _html} = live(login(build_conn(), stranger), ~p"/goals/#{goal.id}")

      refute has_element?(view, "#goal-share")
    end
  end

  # El comentario del usuario sobre el detalle del goal: agrupado por status,
  # editable y con el estado a la vista.
  describe "las tasks del detalle (agrupado, editable, con status)" do
    test "el estado se ve por grupo y cada task se puede editar", %{author: author, conn: conn} do
      goal = goal!(author, %{"title" => "Con grupo"})
      {:ok, t1} = Tasks.create_task(%{"goal_id" => goal.id, "title" => "Backlog uno"})
      {:ok, _t2} = Tasks.create_task(%{"goal_id" => goal.id, "title" => "Backlog dos"})

      {:ok, t3} =
        Tasks.create_task(%{"goal_id" => goal.id, "title" => "Hecha", "status" => "done"})

      {:ok, view, html} = live(login(conn, author), ~p"/goals/#{goal.id}")

      # Agrupadas por status, con el encabezado del grupo.
      assert html =~ t("Backlog")
      assert html =~ t("Done")
      assert has_element?(view, "#tasks-#{t1.id}[data-status='backlog']")
      assert has_element?(view, "#tasks-#{t3.id}[data-status='done']")

      # Editable SIEMPRE en modal: el form no vive dentro de la tarjeta.
      refute has_element?(view, "#goal-task-edit-form-#{t1.id}")

      # Y la lista NO lleva select de estado (el que estaba ofrecía estados de
      # GOAL, no de task): el estado se cambia en el modal de edición.
      refute has_element?(view, "#goal-task-move-#{t1.id}")
      refute has_element?(view, "#goal-task-status-#{t1.id}")
      assert has_element?(view, "#goal-task-edit-#{t1.id}")

      view |> element("#goal-task-edit-#{t1.id}") |> render_click()

      assert has_element?(view, "#goal-task-edit-modal #goal-task-edit-form-#{t1.id}")

      # El modal de edición tiene los MISMOS campos que el alta MÁS los pasos:
      # la task se edita igual acá y en el board (`DranWeb.TaskComponents`).
      for field <- ~w(title editor status priority due checklist) do
        assert has_element?(view, "#goal-task-edit-#{t1.id}-#{field}")
      end

      # Y el borrado está en el footer del mismo modal (igual que en el board).
      assert has_element?(view, "#goal-task-edit-#{t1.id}-delete")

      # El editor llega con el cuerpo de ESA task (y lo manda como task[body]).
      {:ok, _} =
        Tasks.update_task(Dran.Repo.get!(Tasks.Task, t1.id), %{"body" => "**Cuerpo** en markdown"})

      view |> render_click("close_edit_modal")
      refute has_element?(view, "#goal-task-edit-modal")
      view |> element("#goal-task-edit-#{t1.id}") |> render_click()

      assert has_element?(
               view,
               "#goal-task-edit-#{t1.id}-editor[data-body='**Cuerpo** en markdown']"
             )

      assert has_element?(view, "#goal-task-edit-form-#{t1.id} input[name='task[body]']")

      # Y el submit escribe el cuerpo que trae el form (el hidden que el editor
      # sincroniza): se ve cambiando la fila por detrás y guardando el form.
      {:ok, _} =
        Tasks.update_task(Dran.Repo.get!(Tasks.Task, t1.id), %{"body" => "otro cuerpo"})

      view
      |> form("#goal-task-edit-form-#{t1.id}",
        task: %{"title" => "Editada", "body" => "**Cuerpo** en markdown"},
        task_id: t1.id
      )
      |> render_submit()

      assert Dran.Repo.get!(Tasks.Task, t1.id).body == "**Cuerpo** en markdown"

      # El mismo submit guardó el título (es un solo form, un solo caso de uso)
      # y cerró el modal.
      assert Dran.Repo.get!(Tasks.Task, t1.id).title == "Editada"
      refute has_element?(view, "#goal-task-edit-modal")

      # El estado se cambia desde el modal y se guarda por la puerta del dominio
      # (`Tasks.move_task/2`, dentro del caso de uso único): el grupo y el
      # progreso lo siguen.
      view |> element("#goal-task-edit-#{t1.id}") |> render_click()

      view
      |> form("#goal-task-edit-form-#{t1.id}",
        task: %{"title" => "Editada", "status" => "done"},
        task_id: t1.id
      )
      |> render_submit()

      assert Dran.Repo.get!(Tasks.Task, t1.id).status == "done"
      assert has_element?(view, "#tasks-#{t1.id}[data-status='done']")
      assert has_element?(view, "#goal-progress[data-done='2'][data-total='3']")

      # Los pasos también están en el modal, y el editor llega con el array de la
      # task. (La ESCRITURA de los pasos se prueba en `Dran.TasksSaveEditTest`:
      # el hidden del editor es un valor fijado por el render y el helper de
      # formularios no deja forjar otro.)
      {:ok, _} =
        Tasks.set_checklist(Dran.Repo.get!(Tasks.Task, t1.id), [
          %{"id" => "s1", "text" => "Paso uno", "done" => false}
        ])

      view |> element("#goal-task-edit-#{t1.id}") |> render_click()

      assert has_element?(
               view,
               "#goal-task-edit-#{t1.id}-checklist-row-0 input[value='Paso uno']"
             )
    end

    test "borrar la task desde su modal: la misma puerta que el board", %{
      author: author,
      conn: conn
    } do
      goal = goal!(author, %{"title" => "Para borrar"})
      {:ok, task} = Tasks.create_task(%{"goal_id" => goal.id, "title" => "Sobra"})

      {:ok, view, _html} = live(login(conn, author), ~p"/goals/#{goal.id}")

      assert has_element?(view, "#tasks-#{task.id}")

      view |> element("#goal-task-edit-#{task.id}") |> render_click()
      assert has_element?(view, "#goal-task-edit-modal #goal-task-edit-#{task.id}-delete")

      view |> element("#goal-task-edit-#{task.id}-delete") |> render_click()

      refute Dran.Repo.get(Tasks.Task, task.id)
      refute has_element?(view, "#tasks-#{task.id}")
      refute has_element?(view, "#goal-task-edit-modal")
    end
  end

  # ── El índice: UN molde de tarjeta y los filtros en la URL ────────────────
  #
  # El índice de goals y el de plans son la MISMA lista: estado con su etiqueta,
  # progreso derivado, vencimiento, destino y sello de actualizado — más los
  # filtros (estado + orden) en la URL, como los del board.

  describe "el índice: molde de tarjeta y filtros" do
    test "la tarjeta muestra estado, progreso, vencimiento y destino", %{
      author: author,
      conn: conn
    } do
      goal =
        goal!(author, %{
          "title" => "Con data",
          "status" => "active",
          "due_on" => ~D[2026-10-09],
          "visibility" => "public"
        })

      {:ok, view, _html} = live(login(conn, author), ~p"/goals")

      card = "#goal-card-#{goal.id}"
      html = render(element(view, card))

      # Las cuatro fichas del molde, en la misma tarjeta.
      assert html =~ "0/0"
      assert html =~ "Oct 09"
      assert html =~ t("Updated")
      assert html =~ "Active"
      assert has_element?(view, "#{card} [data-chip='progress']")
      assert has_element?(view, "#{card} [data-chip='due']")
      assert has_element?(view, "#{card}-visibility")
    end

    test "el progreso de la tarjeta sale de las tasks vivas", %{author: author, conn: conn} do
      goal = goal!(author, %{"title" => "Con tasks"})

      {:ok, _} = Tasks.create_task(%{"goal_id" => goal.id, "title" => "Una", "status" => "done"})
      {:ok, _} = Tasks.create_task(%{"goal_id" => goal.id, "title" => "Dos"})

      {:ok, archived} =
        Tasks.create_task(%{"goal_id" => goal.id, "title" => "Archivada", "status" => "done"})

      {:ok, _} = Tasks.update_task(archived, %{"archived" => true})

      {:ok, view, _html} = live(login(conn, author), ~p"/goals")

      # El progreso es el DERIVADO de las tasks no archivadas (1 de 2): el
      # índice lo lee en una sola consulta agregada, no goal por goal.
      assert has_element?(view, "#goal-card-#{goal.id} [data-chip='progress']", "1/2")
    end

    test "privado no pinta la píldora del destino y lo vencido va en rojo", %{
      author: author,
      conn: conn
    } do
      private = goal!(author, %{"title" => "Privado"})

      late =
        goal!(author, %{"title" => "Vencido", "due_on" => Date.add(Date.utc_today(), -5)})

      {:ok, view, _html} = live(login(conn, author), ~p"/goals")

      refute has_element?(view, "#goal-card-#{private.id}-visibility")

      # Vencido = fecha pasada y sin cerrar: la ficha se pinta en error.
      assert has_element?(view, "#goal-card-#{late.id} [data-chip='due'].bg-red-100")
    end

    test "los filtros viven en la URL y recortan la lista", %{author: author, conn: conn} do
      active = goal!(author, %{"title" => "Activo", "status" => "active"})
      draft = goal!(author, %{"title" => "Borrador", "status" => "draft"})

      {:ok, view, _html} = live(login(conn, author), ~p"/goals")

      assert has_element?(view, "#goals-filters")
      assert has_element?(view, "#goals-status-filter")
      assert has_element?(view, "#goals-order-filter")
      assert has_element?(view, "#goal-card-#{active.id}")
      assert has_element?(view, "#goal-card-#{draft.id}")

      # El cambio es un patch: el filtro queda en la URL (compartible) y el
      # contenedor del stream sobrevive.
      view |> form("#goals-filters", %{"status" => "draft"}) |> render_change()

      assert_patch(view, ~p"/goals?status=draft")
      assert has_element?(view, "#goal-card-#{draft.id}")
      refute has_element?(view, "#goal-card-#{active.id}")
      assert has_element?(view, "#goals[phx-update='stream']")

      # Sin resultados: el vacío NO ofrece crear (ese es el de la colección).
      view |> form("#goals-filters", %{"status" => "done"}) |> render_change()

      refute has_element?(view, "[data-testid='empty-state']")
    end

    test "el orden por vencer deja al final lo que no tiene fecha", %{
      author: author,
      conn: conn
    } do
      none = goal!(author, %{"title" => "Sin fecha"})
      late = goal!(author, %{"title" => "Tarde", "due_on" => ~D[2026-12-01]})
      soon = goal!(author, %{"title" => "Pronto", "due_on" => ~D[2026-10-09]})

      {:ok, view, _html} = live(login(conn, author), ~p"/goals")

      html = render(view)

      assert before?(html, "goal-card-#{soon.id}", "goal-card-#{late.id}")
      assert before?(html, "goal-card-#{late.id}", "goal-card-#{none.id}")

      # Y el orden es un filtro más: viaja en la URL.
      view |> form("#goals-filters", %{"order" => "title"}) |> render_change()

      assert_patch(view, ~p"/goals?order=title")
    end

    test "un filtro forjado no filtra ni rompe", %{author: author, conn: conn} do
      goal = goal!(author, %{"title" => "Visible"})

      # `?status=<basura>` se descarta (no hay filtro aplicado sin control que lo
      # explique) y `?order=` desconocido cae al default.
      {:ok, view, _html} = live(login(conn, author), ~p"/goals?status=<script>&order=loquesea")

      assert has_element?(view, "#goal-card-#{goal.id}")
      assert has_element?(view, "#goals-status-filter option[value=''][selected]")
    end
  end

  # ── El summary es de la máquina ───────────────────────────────────────────
  #
  # Lo escriben los agentes y workers (REST + augmentation), no la persona:
  # ningún form lo pide, y por eso editar desde la UI no lo borra. Se LEE.

  describe "el summary es de la máquina" do
    test "no hay input en el alta ni en la edición, y el texto se muestra", %{
      author: author,
      conn: conn
    } do
      goal = goal!(author, %{"title" => "Con resumen", "summary" => "Lo escribió un worker"})

      {:ok, view, _html} = live(login(conn, author), ~p"/goals?new=true")

      refute has_element?(view, "input[name='goal[summary]']")
      refute has_element?(view, "textarea[name='goal[summary]']")

      {:ok, view, _html} = live(login(conn, author), ~p"/goals/#{goal.id}?edit=true")

      refute has_element?(view, "input[name='goal[summary]']")

      # Editarlo desde la UI no se lo lleva puesto: el cast no toca lo que no
      # viaja, así que lo del worker sobrevive.
      view
      |> form("#goal-form", %{"goal" => %{"title" => "Renombrado"}})
      |> render_submit()

      updated = Goals.get_goal(goal.id)
      assert updated.title == "Renombrado"
      assert updated.summary == "Lo escribió un worker"

      # Y se LEE donde va: subtítulo del detalle y tarjeta del índice.
      {:ok, view, _html} = live(login(conn, author), ~p"/goals/#{goal.id}")
      assert render(view) =~ "Lo escribió un worker"

      {:ok, view, _html} = live(login(conn, author), ~p"/goals")
      assert render(element(view, "#goal-card-#{goal.id}")) =~ "Lo escribió un worker"
    end
  end

  describe "páginas relacionadas (W5)" do
    # El sidebar lee con la puerta PERSONAL y declara CUÁL fuente está
    # mostrando: relaciones del grafo o fallback semántico. Sin inferencia real
    # (el fallback no puede llamar a la red en tests).
    setup do
      original = Application.get_env(:dran, :inference)

      Application.put_env(:dran, :inference,
        base_url: nil,
        api_key: nil,
        embedding_model: nil,
        timeout: 100,
        schedule_async: false
      )

      on_exit(fn ->
        if is_nil(original) do
          Application.delete_env(:dran, :inference)
        else
          Application.put_env(:dran, :inference, original)
        end
      end)

      :ok
    end

    test "lista la relación real y declara su fuente", %{author: author, conn: conn} do
      goal = goal!(author, %{"title" => "Con vecinos"})
      page = page!(author, "Página vinculada", "public")
      {:ok, _} = Related.link("goal", goal, page.id, author, scope: {:reader, author.id})

      {:ok, view, _html} = live(login(conn, author), ~p"/goals/#{goal.id}")

      assert has_element?(view, "#goal-related")
      assert has_element?(view, "#goal-related-source", t("From the graph"))
      assert has_element?(view, "#goal-related-page-#{page.id}", "Página vinculada")
    end

    test "sin relaciones ni vecinos declara que no hay ninguna fuente", %{
      author: author,
      conn: conn
    } do
      goal = goal!(author, %{"title" => "Solo"})

      {:ok, view, _html} = live(login(conn, author), ~p"/goals/#{goal.id}")

      assert has_element?(view, "#goal-related-source", t("None"))
      assert has_element?(view, "#goal-related", t("No related pages yet."))
    end

    test "el picker da de alta la relación y el sidebar la muestra como relación", %{
      author: author,
      conn: conn
    } do
      goal = goal!(author, %{"title" => "Con picker"})
      page = page!(author, "Página elegida", "public")

      {:ok, view, _html} = live(login(conn, author), ~p"/goals/#{goal.id}")

      assert has_element?(view, "#goal-related-link-form")

      view
      |> form("#goal-related-link-form", page_id: page.id)
      |> render_submit()

      # La arista existe y queda ATRIBUIDA a quien la creó…
      relation =
        Dran.Repo.one(
          from r in Dran.Relation,
            where: r.source_id == ^goal.id and r.target_type == "page"
        )

      assert relation.target_id == page.id
      assert relation.relation_type == "related"
      assert relation.meta["created_by_user_id"] == author.id

      # …y el sidebar ya la declara como relación real, no como sugerencia.
      assert has_element?(view, "#goal-related-source", t("From the graph"))
      assert has_element?(view, "#goal-related-page-#{page.id}", "Página elegida")
    end

    test "no lista la página que el lector NO puede leer", %{
      author: author,
      stranger: stranger,
      conn: conn
    } do
      # Goal público (el tercero lo abre), página privada del autor: la relación
      # existe pero el lector ajeno no la ve — ni por el sidebar ni por el
      # fallback.
      goal = goal!(author, %{"title" => "Público con privada", "visibility" => "public"})
      hidden = page!(author, "Privada del autor", "private")
      {:ok, _} = Related.link("goal", goal, hidden.id, author, scope: {:reader, author.id})

      {:ok, view, _html} = live(login(conn, stranger), ~p"/goals/#{goal.id}")

      assert has_element?(view, "#goal-related")
      refute has_element?(view, "#goal-related-page-#{hidden.id}")
    end

    test "el picker no ofrece la página que el lector no puede leer", %{
      author: author,
      stranger: stranger,
      conn: conn
    } do
      goal = goal!(author, %{"title" => "Público sin opciones", "visibility" => "public"})
      _hidden = page!(author, "Privada del autor", "private")
      _visible = page!(author, "Pública del autor", "public")

      {:ok, view, _html} = live(login(conn, stranger), ~p"/goals/#{goal.id}")

      assert has_element?(view, "#goal-related-link-form")

      html = render(view)

      # El picker ofrece lo legible y NUNCA lo que el lector no puede leer.
      assert html =~ "Pública del autor"
      refute html =~ "Privada del autor"
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp page!(owner, title, visibility) do
    workspace = Dran.DataCase.ensure_workspace!()

    {:ok, page} =
      Knowledge.create_page(%{
        workspace_id: workspace.id,
        title: title,
        body: "cuerpo de #{title}",
        page_type: "note",
        visibility: visibility,
        owner_user_id: owner.id
      })

    page
  end

  defp t(msgid), do: Gettext.gettext(DranWeb.Gettext, msgid)

  # Posición de una tarjeta en el DOM: el orden se afirma sobre el HTML, no
  # sobre una lista de assigns.
  defp before?(html, first, second) do
    {first_pos, _len} = :binary.match(html, first)
    {second_pos, _len} = :binary.match(html, second)
    assert first_pos < second_pos
    true
  end

  defp login(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:user, user.email)
    |> Plug.Conn.put_session(:is_owner, false)
    |> Plug.Conn.put_session(:workspace_slug, "personal")
  end

  defp goal!(owner, attrs) do
    {:ok, goal} =
      Goals.create_goal(Map.merge(%{"owner_user_id" => owner.id}, attrs))

    goal
  end

  defp only_goal(owner) do
    [goal] = Goals.list_goals(owner_user_id: owner.id)
    goal
  end
end
