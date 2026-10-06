defmodule DranWeb.PlanLiveTest do
  @moduledoc """
  Gate W4 (contrato de superficies): la web del plan y su checklist.

  - P12: crear, editar y borrar desde la UI sella al AUTOR como dueño y deja lo
    privado invisible a un tercero (ni por URL);
  - P9: el checklist se administra desde la web sobre la MISMA fila — tachar un
    paso va por `Plans.toggle_checklist/3` (el RMW con `lock_version`) y el
    editor guarda con `set_checklist/3`;
  - Constraint 8: tachar un paso no crea ni mueve tasks, y el progreso se DERIVA
    del checklist (nunca se guarda).
  """

  use DranWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Dran.{Accounts, Knowledge, Plans, Related, Tasks}

  import Ecto.Query, only: [from: 2]

  setup do
    Dran.DataCase.ensure_workspace!()
    u = System.unique_integer([:positive])

    {:ok, author} =
      Accounts.create_user(%{
        email: "plan-live-author-#{u}@example.com",
        name: "Author",
        api_token: "tok-plan-live-#{u}"
      })

    {:ok, stranger} =
      Accounts.create_user(%{
        email: "plan-live-stranger-#{u}@example.com",
        name: "Stranger",
        api_token: "tok-plan-stranger-#{u}"
      })

    %{author: author, stranger: stranger}
  end

  describe "crear y editar (P12)" do
    test "el plan nace con sus pasos, con el autor como dueño y privado", %{
      author: author,
      conn: conn
    } do
      {:ok, view, _html} = live(login(conn, author), ~p"/plans?new=true")

      # El editor de checklist reescribe el input oculto en el cliente: el
      # evento llega con el JSON ya editado (igual que un submit real).
      render_submit(view, "save_plan", %{
        "plan" => %{"title" => "Lanzamiento", "status" => "active", "visibility" => "private"},
        "steps" => Jason.encode!(["uno", %{"text" => "dos", "done" => true}])
      })

      plan = only_plan(author)
      assert_redirect(view, ~p"/plans/#{plan.id}")
      assert plan.owner_user_id == author.id
      assert plan.visibility == "private"

      assert plan.checklist == [
               %{"text" => "uno", "done" => false},
               %{"text" => "dos", "done" => true}
             ]
    end

    test "el detalle muestra los pasos y el progreso derivado", %{author: author, conn: conn} do
      plan = plan!(author, %{"title" => "Con pasos", "checklist" => ["uno", "dos", "tres"]})

      {:ok, view, _html} = live(login(conn, author), ~p"/plans/#{plan.id}")

      # Los pasos se ven en el editor (una sola lista) y el progreso se deriva.
      assert has_element?(view, "#plan-steps-detail")
      assert has_element?(view, "#plan-steps-detail-row-0")
      assert has_element?(view, "#plan-steps-detail-row-2")
      assert has_element?(view, "#plan-progress[data-total='3'][data-done='0']")
    end

    test "editar cambia el título EN la página y vuelve al detalle", %{author: author, conn: conn} do
      plan = plan!(author, %{"title" => "Antes"})

      # La edición es `?edit=true` sobre el MISMO LiveView del detalle: no hay
      # ruta /edit y el guardado sale del modo edición con un patch.
      {:ok, view, _html} = live(login(conn, author), ~p"/plans/#{plan.id}?edit=true")

      assert has_element?(view, "#plan-edit-panel")

      view
      |> form("#plan-form", %{"plan" => %{"title" => "Después", "status" => "active"}})
      |> render_submit()

      assert_patch(view, ~p"/plans/#{plan.id}")
      assert Dran.Repo.get!(Plans.Plan, plan.id).title == "Después"
    end

    test "borrar se lleva el plan", %{author: author, conn: conn} do
      plan = plan!(author, %{"title" => "Borrable"})

      {:ok, view, _html} = live(login(conn, author), ~p"/plans/#{plan.id}")
      view |> element("#plan-delete") |> render_click()

      assert_redirect(view, ~p"/plans")
      assert Dran.Repo.get(Plans.Plan, plan.id) == nil
    end
  end

  describe "el checklist en la web (P9)" do
    test "los pasos viven en UN solo lugar: el editor del detalle", %{author: author, conn: conn} do
      plan = plan!(author, %{"title" => "Un solo lugar", "checklist" => ["uno", "dos"]})

      {:ok, view, _html} = live(login(conn, author), ~p"/plans/#{plan.id}")

      # La lista duplicada del detalle murió (el comentario: «estos quitarlos,
      # solo usar los de abajo»): los pasos se ven y se tocan en el editor.
      refute has_element?(view, "#plan-steps-list")
      refute has_element?(view, "#plan-step-0")
      assert has_element?(view, "#plan-steps-form")
      assert has_element?(view, "#plan-steps-detail")
      # El badge del encabezado sigue contando los pasos.
      assert has_element?(view, "#plan-progress[data-done='0'][data-total='2']")
    end

    test "tachar un paso sube el progreso y NO crea tasks", %{author: author, conn: conn} do
      plan = plan!(author, %{"title" => "Pasos", "checklist" => ["uno", "dos"]})
      tasks_before = Dran.Repo.aggregate(Tasks.Task, :count, :id)

      {:ok, view, _html} = live(login(conn, author), ~p"/plans/#{plan.id}")

      # El editor es la puerta: se guarda el array con el primer paso tachado.
      render_submit(view, "save_checklist", %{
        "steps" =>
          Jason.encode!([%{"text" => "uno", "done" => true}, %{"text" => "dos", "done" => false}])
      })

      assert has_element?(view, "#plan-progress[data-done='1'][data-total='2']")
      assert Dran.Repo.get!(Plans.Plan, plan.id).checklist |> Enum.at(0) |> Map.get("done")

      # Tachar un paso es texto que se tacha: cero tasks, cero movimientos.
      assert Dran.Repo.aggregate(Tasks.Task, :count, :id) == tasks_before

      # Y se puede destachar.
      render_submit(view, "save_checklist", %{
        "steps" =>
          Jason.encode!([
            %{"text" => "uno", "done" => false},
            %{"text" => "dos", "done" => false}
          ])
      })

      assert has_element?(view, "#plan-progress[data-done='0'][data-total='2']")
    end

    test "el editor agrega y quita pasos (reescribe el array)", %{author: author, conn: conn} do
      plan = plan!(author, %{"title" => "Reescribir", "checklist" => ["uno"]})

      {:ok, view, _html} = live(login(conn, author), ~p"/plans/#{plan.id}")

      render_submit(view, "save_checklist", %{"steps" => Jason.encode!(["uno", "dos", "tres"])})

      assert has_element?(view, "#plan-steps-detail-row-2")
      assert Dran.Repo.get!(Plans.Plan, plan.id).checklist |> length() == 3

      render_submit(view, "save_checklist", %{"steps" => Jason.encode!(["uno"])})

      assert Dran.Repo.get!(Plans.Plan, plan.id).checklist == [
               %{"text" => "uno", "done" => false}
             ]
    end

    test "la lista muestra el progreso de cada plan", %{author: author, conn: conn} do
      plan = plan!(author, %{"title" => "Con progreso", "checklist" => ["uno", "dos"]})

      {:ok, view, _html} = live(login(conn, author), ~p"/plans")

      assert has_element?(view, "#plan-card-#{plan.id}")
      assert has_element?(view, "#plan-new")
    end
  end

  describe "aislamiento (P12)" do
    test "un plan ajeno privado no se abre ni por URL", %{author: author, stranger: stranger} do
      plan = plan!(author, %{"title" => "Privado"})

      assert {:error, {:live_redirect, %{to: "/plans"}}} =
               live(login(build_conn(), stranger), ~p"/plans/#{plan.id}")

      assert {:error, {:live_redirect, %{to: "/plans"}}} =
               live(login(build_conn(), stranger), ~p"/plans/#{plan.slug}")
    end

    test "el tercero no ve el plan en la lista", %{author: author, stranger: stranger} do
      plan = plan!(author, %{"title" => "Ajeno"})

      {:ok, view, _html} = live(login(build_conn(), stranger), ~p"/plans")

      refute has_element?(view, "#plan-card-#{plan.id}")
    end

    test "una sesión sin fila en users navega fuera (fail-closed)", %{conn: conn} do
      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session(:user, "ghost@no.row")
        |> Plug.Conn.put_session(:workspace_slug, "personal")

      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/plans")
      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/plans?new=true")
    end
  end

  describe "la estructura de pages (modal y edición en página)" do
    test "el CTA abre el alta en un modal con ?new=true, no navegando", %{
      author: author,
      conn: conn
    } do
      {:ok, view, _html} = live(login(conn, author), ~p"/plans")

      refute has_element?(view, "#plan-resource-modal")

      view |> element("#plan-new") |> render_click()

      assert_patch(view, ~p"/plans?new=true")
      assert has_element?(view, "#plan-resource-modal")
      assert has_element?(view, "#plan-resource-modal #plan-form")
      assert has_element?(view, "#plan-editor[phx-hook='MarkdownEditor']")
      # El editor de pasos vive en el alta (en el detalle tiene su propia puerta).
      assert has_element?(view, "#plan-steps")
    end

    test "cerrar el modal vuelve a la lista con un patch (el stream sobrevive)", %{
      author: author,
      conn: conn
    } do
      plan!(author, %{"title" => "Visible"})

      {:ok, view, _html} = live(login(conn, author), ~p"/plans?new=true")
      assert has_element?(view, "#plan-resource-modal")

      render_click(view, "close_plan_modal")

      assert_patch(view, ~p"/plans")
      refute has_element?(view, "#plan-resource-modal")
      assert has_element?(view, "#plan-card-#{only_plan(author).id}")
    end

    test "el detalle alterna Edit y View con ?edit=true y los pasos siguen ahí", %{
      author: author,
      conn: conn
    } do
      plan = plan!(author, %{"title" => "Con panel", "checklist" => ["uno"]})

      {:ok, view, _html} = live(login(conn, author), ~p"/plans/#{plan.id}")
      assert has_element?(view, "#plan-edit")
      refute has_element?(view, "#plan-edit-panel")

      view |> element("#plan-edit") |> render_click()

      assert_patch(view, ~p"/plans/#{plan.id}?edit=true")
      assert has_element?(view, "#plan-edit-panel")
      assert has_element?(view, "#plan-view")
      # El panel de pasos no se va con el modo edición: el checklist es del
      # detalle, no del form (y es el EDITOR de pasos, no una lista aparte).
      assert has_element?(view, "#plan-steps-form")
      assert has_element?(view, "#plan-steps-detail")
      refute has_element?(view, "#plan-steps-list")

      render_submit(view, "save_checklist", %{
        "steps" => Jason.encode!([%{"text" => "uno", "done" => true}])
      })

      assert has_element?(view, "#plan-progress[data-done='1'][data-total='1']")

      view |> element("#plan-view") |> render_click()

      assert_patch(view, ~p"/plans/#{plan.id}")
      refute has_element?(view, "#plan-edit-panel")
    end
  end

  # El estándar de la LISTA (contrato de paridad UI/UX, W5).
  describe "el estándar de la lista (pages)" do
    test "sin planes el índice muestra el estado vacío estándar y su CTA", %{
      author: author,
      conn: conn
    } do
      {:ok, view, _html} = live(login(conn, author), ~p"/plans")

      assert has_element?(view, "[data-testid='empty-state']")
      assert has_element?(view, "[data-testid='empty-state'] h3", "No plans yet")
      assert has_element?(view, "[data-testid='empty-state'] a[href='/plans?new=true']")
      assert has_element?(view, "[data-testid='new-plan-button']")
      assert has_element?(view, "#plans[phx-update='stream']")
    end

    test "con planes la tarjeta es la estándar y lleva el progreso", %{author: author, conn: conn} do
      plan = plan!(author, %{"title" => "Estándar", "checklist" => ["uno", "dos"]})

      {:ok, view, _html} = live(login(conn, author), ~p"/plans")

      refute has_element?(view, "[data-testid='empty-state']")
      assert has_element?(view, "[data-testid='plan-card-#{plan.id}']")
      assert has_element?(view, "#plan-card-#{plan.id}.surface-2.lift")
      assert has_element?(view, "#plan-card-#{plan.id} .size-8")
      assert render(view) =~ "0/2"
      assert has_element?(view, "#plans.space-y-2")
      refute has_element?(view, "#plans.grid")
    end
  end

  # El destino (scope) es UNO (mismo control y misma píldora que pages).
  describe "el destino (scope) es el estándar" do
    test "el alta declara el destino con el control compartido", %{author: author, conn: conn} do
      {:ok, view, _html} = live(login(conn, author), ~p"/plans?new=true")

      assert has_element?(view, "#plan-visibility-picker")

      # El control vive en el HEADER del modal, junto a la ✕ (no en el form del
      # body): sus radios lo apuntan con el atributo HTML `form`, que es lo que
      # los hace viajar en el submit.
      assert has_element?(view, "#plan-resource-modal-header-actions #plan-visibility-picker")
      refute has_element?(view, "#plan-form #plan-visibility-picker")

      assert has_element?(
               view,
               "#plan-resource-modal-header-actions input[name='plan[visibility]'][form='plan-form']"
             )

      assert has_element?(view, "form#plan-form")

      # UN input por nivel, DENTRO de su label: el click marca el radio y el CSS
      # pinta el pill activo (has-[:checked]) — sin JS y sin round-trip.
      for level <- ~w(private public shared) do
        assert has_element?(view, "#plan-visibility-picker label input[value='#{level}']")
      end

      # Y ninguno de más: el input hidden duplicado (el doble valor viejo) murió.
      refute has_element?(view, "#plan-visibility-picker input[type='hidden']")

      assert has_element?(view, "input[name='plan[visibility]'][value='private']")
      assert has_element?(view, "#plan_visibility-private")
      assert has_element?(view, "#plan_visibility-public")
      assert has_element?(view, "#plan_visibility-shared")

      # Y el nivel elegido viaja y SE GUARDA: el pill no era sólo decorativo.
      view
      |> form("#plan-form", %{"plan" => %{"title" => "Publico elegido", "visibility" => "public"}})
      |> render_submit()

      assert only_plan(author).visibility == "public"
    end

    test "la píldora traduce el destino y se oculta en privado", %{author: author, conn: conn} do
      plan = plan!(author, %{"title" => "Privado"})

      {:ok, view, _html} = live(login(conn, author), ~p"/plans/#{plan.id}")
      refute has_element?(view, "#plan-visibility-badge")

      {:ok, pub} = Dran.Plans.update_plan(plan, %{"visibility" => "public"})

      {:ok, view, _html} = live(login(conn, author), ~p"/plans/#{pub.id}")
      assert has_element?(view, "#plan-visibility-badge", t("Public"))
    end
  end

  # ── El índice: UN molde de tarjeta y los filtros en la URL ────────────────
  #
  # El índice de plans y el de goals son la MISMA lista: estado con su etiqueta,
  # progreso derivado, vencimiento, destino y sello de actualizado — más los
  # filtros (estado + orden) en la URL, como los del board.

  describe "el índice: molde de tarjeta y filtros" do
    test "la tarjeta muestra estado, progreso, vencimiento y destino", %{
      author: author,
      conn: conn
    } do
      plan =
        plan!(author, %{
          "title" => "Con data",
          "status" => "active",
          "due_on" => ~D[2026-10-09],
          "visibility" => "shared",
          "checklist" => ["uno", "dos"]
        })

      {:ok, view, _html} = live(login(conn, author), ~p"/plans")

      card = "#plan-card-#{plan.id}"
      html = render(element(view, card))

      # Las cuatro fichas del molde, en la misma tarjeta.
      assert html =~ "0/2"
      assert html =~ "Oct 09"
      assert html =~ t("Updated")
      assert html =~ "Active"
      assert has_element?(view, "#{card} [data-chip='progress']")
      assert has_element?(view, "#{card} [data-chip='due']")
      assert has_element?(view, "#{card}-visibility")
    end

    test "el listado pinta el destino de cada fila, privado incluido, y lo vencido va en rojo", %{
      author: author,
      conn: conn
    } do
      private = plan!(author, %{"title" => "Privado"})

      late =
        plan!(author, %{"title" => "Vencido", "due_on" => Date.add(Date.utc_today(), -5)})

      {:ok, view, _html} = live(login(conn, author), ~p"/plans")

      # El scope se ve en TODAS las filas: en un listado el lector compara
      # destinos y el hueco de `private` se leía como «sin dato».
      assert has_element?(view, "#plan-card-#{private.id}-visibility", t("Private"))

      # Vencido = fecha pasada y sin cerrar: la ficha se pinta en error.
      assert has_element?(view, "#plan-card-#{late.id} [data-chip='due'].bg-red-100")
    end

    test "los filtros viven en la URL y recortan la lista", %{author: author, conn: conn} do
      active = plan!(author, %{"title" => "Activo", "status" => "active"})
      draft = plan!(author, %{"title" => "Borrador", "status" => "draft"})

      {:ok, view, _html} = live(login(conn, author), ~p"/plans")

      assert has_element?(view, "#plans-filters")
      assert has_element?(view, "#plans-status-filter")
      assert has_element?(view, "#plans-order-filter")
      assert has_element?(view, "#plan-card-#{active.id}")
      assert has_element?(view, "#plan-card-#{draft.id}")

      # El cambio es un patch: el filtro queda en la URL (compartible) y el
      # contenedor del stream sobrevive.
      view |> form("#plans-filters", %{"status" => "draft"}) |> render_change()

      assert_patch(view, ~p"/plans?status=draft")
      assert has_element?(view, "#plan-card-#{draft.id}")
      refute has_element?(view, "#plan-card-#{active.id}")
      assert has_element?(view, "#plans[phx-update='stream']")

      # Sin resultados: el vacío NO ofrece crear (ese es el de la colección).
      view |> form("#plans-filters", %{"status" => "done"}) |> render_change()

      refute has_element?(view, "[data-testid='empty-state']")
    end

    test "el orden es un filtro más y viaja en la URL", %{author: author, conn: conn} do
      plan!(author, %{"title" => "Uno"})

      {:ok, view, _html} = live(login(conn, author), ~p"/plans")

      # El default (por vencer) no ensucia la URL: filtrar por estado no agrega
      # `order`.
      view |> form("#plans-filters", %{"status" => "active"}) |> render_change()

      assert_patch(view, ~p"/plans?status=active")

      view |> form("#plans-filters", %{"order" => "title"}) |> render_change()

      assert_patch(view, ~p"/plans?status=active&order=title")

      # Y el estado del control sigue lo que dice la URL.
      {:ok, view, _html} = live(login(conn, author), ~p"/plans?order=title&status=active")

      assert has_element?(view, "#plans-order-filter option[value='title'][selected]")
      assert has_element?(view, "#plans-status-filter option[value='active'][selected]")
    end

    test "un filtro forjado no filtra ni rompe", %{author: author, conn: conn} do
      plan = plan!(author, %{"title" => "Visible"})

      {:ok, view, _html} = live(login(conn, author), ~p"/plans?status=<script>&order=loquesea")

      assert has_element?(view, "#plan-card-#{plan.id}")
      assert has_element?(view, "#plans-status-filter option[value=''][selected]")
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
      plan = plan!(author, %{"title" => "Con resumen", "summary" => "Lo escribió un worker"})

      {:ok, view, _html} = live(login(conn, author), ~p"/plans?new=true")

      refute has_element?(view, "input[name='plan[summary]']")
      refute has_element?(view, "textarea[name='plan[summary]']")

      {:ok, view, _html} = live(login(conn, author), ~p"/plans/#{plan.id}?edit=true")

      refute has_element?(view, "input[name='plan[summary]']")

      # Editarlo desde la UI no se lo lleva puesto: el cast no toca lo que no
      # viaja, así que lo del worker sobrevive.
      view
      |> form("#plan-form", %{"plan" => %{"title" => "Renombrado"}})
      |> render_submit()

      updated = Plans.get_plan(plan.id)
      assert updated.title == "Renombrado"
      assert updated.summary == "Lo escribió un worker"

      # Y se LEE donde va: subtítulo del detalle y tarjeta del índice.
      {:ok, view, _html} = live(login(conn, author), ~p"/plans/#{plan.id}")
      assert render(view) =~ "Lo escribió un worker"

      {:ok, view, _html} = live(login(conn, author), ~p"/plans")
      assert render(element(view, "#plan-card-#{plan.id}")) =~ "Lo escribió un worker"
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  # El sidebar de un PLAN: la misma puerta que el de un goal, con su extremo.
  describe "páginas relacionadas (W5)" do
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

    test "lista la relación real del plan y declara su fuente", %{author: author, conn: conn} do
      plan = plan!(author, %{"title" => "Con vecinos"})
      page = page!(author, "Página del plan", "public")
      {:ok, _} = Related.link("plan", plan, page.id, author, scope: {:reader, author.id})

      {:ok, view, _html} = live(login(conn, author), ~p"/plans/#{plan.id}")

      assert has_element?(view, "#plan-related")
      assert has_element?(view, "#plan-related-source", t("From the graph"))
      assert has_element?(view, "#plan-related-page-#{page.id}", "Página del plan")
    end

    test "el picker del plan da de alta la relación, atribuida", %{author: author, conn: conn} do
      plan = plan!(author, %{"title" => "Con picker"})
      page = page!(author, "Página elegida", "public")

      {:ok, view, _html} = live(login(conn, author), ~p"/plans/#{plan.id}")

      view
      |> form("#plan-related-link-form", page_id: page.id)
      |> render_submit()

      relation =
        Dran.Repo.one(
          from r in Dran.Relation,
            where: r.source_id == ^plan.id and r.source_type == "plan"
        )

      assert relation.target_id == page.id
      assert relation.meta["created_by_user_id"] == author.id
      assert has_element?(view, "#plan-related-source", t("From the graph"))
    end
  end

  # ── W1: el aside del molde (contrato superficies-al-molde) ───────────────

  describe "el aside del detalle (W1)" do
    test "monta el aside con el progreso ARRIBA, relacionados debajo y la metadata al final",
         %{author: author, conn: conn} do
      plan = plan!(author, %{"title" => "Con aside", "checklist" => ["uno", "dos"]})

      {:ok, view, _html} = live(login(conn, author), ~p"/plans/#{plan.id}")

      assert has_element?(view, "#plan-sidebar")

      before?(render(view), ~s(id="plan-progress"), ~s(id="plan-related-section"))
      before?(render(view), ~s(id="plan-related-section"), ~s(id="plan-metadata"))
    end

    test "el progreso vive UNA vez (en el aside) y los PASOS siguen en la principal",
         %{author: author, conn: conn} do
      plan = plan!(author, %{"title" => "Un solo progreso", "checklist" => ["uno", "dos"]})

      {:ok, view, _html} = live(login(conn, author), ~p"/plans/#{plan.id}")

      assert has_element?(view, "#plan-sidebar #plan-progress[data-done='0'][data-total='2']")
      assert length(String.split(render(view), ~s(id="plan-progress"))) == 2

      # El editor de pasos NO se movió al aside: la columna principal lo conserva.
      assert has_element?(view, "#plan-steps-form")
      refute has_element?(view, "#plan-sidebar #plan-steps-form")
    end

    test "la metadata del plan sale de la fila (status, fechas, pasos, destino, dueño, updated)",
         %{author: author, conn: conn} do
      plan =
        plan!(author, %{
          "title" => "Con metadata",
          "status" => "active",
          "visibility" => "shared",
          "starts_on" => ~D[2026-11-01],
          "due_on" => ~D[2026-12-31],
          "checklist" => ["uno", "dos"]
        })

      {:ok, view, _html} = live(login(conn, author), ~p"/plans/#{plan.id}")

      assert has_element?(view, "#plan-metadata", t("Status"))
      assert has_element?(view, "#plan-metadata", t("Active"))
      assert has_element?(view, "#plan-metadata", t("Starts on"))
      assert has_element?(view, "#plan-metadata", "Nov 01, 2026")
      assert has_element?(view, "#plan-metadata", t("Due on"))
      assert has_element?(view, "#plan-metadata", "Dec 31, 2026")
      assert has_element?(view, "#plan-metadata", t("Steps"))
      assert has_element?(view, "#plan-metadata", "2 steps")
      assert has_element?(view, "#plan-metadata", t("Visibility"))
      assert has_element?(view, "#plan-metadata", t("Shared"))
      assert has_element?(view, "#plan-metadata", t("Owner"))
      assert has_element?(view, "#plan-metadata", author.name)
      assert has_element?(view, "#plan-metadata", t("Updated"))
    end

    test "relacionados sigue con su FUENTE declarada dentro del aside",
         %{author: author, conn: conn} do
      plan = plan!(author, %{"title" => "Con vecina"})
      page = page!(author, "Página del aside", "public")
      {:ok, _} = Related.link("plan", plan, page.id, author, scope: {:reader, author.id})

      {:ok, view, _html} = live(login(conn, author), ~p"/plans/#{plan.id}")

      assert has_element?(view, "#plan-sidebar #plan-related-section #plan-related")
      assert has_element?(view, "#plan-sidebar #plan-related-source", t("From the graph"))
      assert has_element?(view, "#plan-related-page-#{page.id}", "Página del aside")
    end
  end

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

  # Posición de un marcador en el HTML: el orden del aside se afirma sobre el DOM.
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

  defp plan!(owner, attrs) do
    {:ok, plan} =
      Plans.create_plan(Map.merge(%{"owner_user_id" => owner.id}, attrs))

    plan
  end

  defp only_plan(owner) do
    [plan] = Plans.list_plans(owner_user_id: owner.id)
    plan
  end
end
