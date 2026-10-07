defmodule DranWeb.PlanLive do
  @moduledoc """
  El plan en la web: lista, detalle y crear/editar/borrar.

  Un plan es una **entidad** con dueño y visibilidad propios (tabla `plans`),
  no un tipo de página: su categoría es `/plans` y sus pasos son el MISMO
  checklist jsonb `[%{text, done}]` de la task (Constraint 8).

  La UI sigue la ESTRUCTURA de pages (contrato de paridad UI/UX): el alta vive
  en un `<.resource_modal>` abierto por estado de URL (`?new=true`) y la edición
  ocurre EN el detalle con `?edit=true` — no existen las rutas `/plans/new` ni
  `/plans/:id/edit`. El shell, el header y las acciones son los componentes
  compartidos (`DranWeb.ResourceComponents`).

  ## El checklist se administra desde acá, sobre la misma fila

  * **el editor de checklist** (el mismo componente que el editor de páginas) es
    la ÚNICA puerta de los pasos: tachar, agregar, quitar y reordenar se
    escriben ahí y se guardan con `Dran.Plans.set_checklist/3` (el RMW del
    contexto, con `lock_version`: la UI nunca escribe el jsonb a mano). La lista
    de pasos duplicada del detalle murió: un paso se ve en un solo lugar.

  Guardar los pasos NO toca las tasks ni el board: tachar un paso no crea trabajo.
  `Dran.Plans.toggle_checklist/3` sigue siendo la puerta del REST (un paso, sin
  reescribir el array).
  """

  use DranWeb, :live_view

  import DranWeb.ResourceComponents,
    only: [
      resource_modal: 1,
      resource_header: 1,
      resource_list_header: 1,
      resource_empty_state: 1,
      resource_card: 1,
      resource_filters: 1,
      resource_scope_field: 1,
      resource_visibility_pill: 1,
      can_manage_scope?: 2,
      related_panel: 1,
      form_actions: 1,
      markdown_body_field: 1,
      order_options: 0,
      overdue?: 1,
      status_class: 1,
      status_label: 1,
      updated_meta: 1,
      # El aside del detalle (mismo molde que pages)
      sidebar_section: 1,
      visibility_label: 1
    ]

  alias Dran.Accounts
  alias Dran.Plans
  alias Dran.Plans.Plan
  alias DranWeb.Components.ShareDialog
  alias DranWeb.Plugs.Auth

  @statuses ~w(draft active on_hold done archived)

  # El orden del listado por default: «por vencer» es lo accionable en un índice
  # de planes. La URL lo OMITE (no hay `?order=due`).
  @default_order "due"

  # ──────────────────────────────────────────────────────────────────────────
  # Render
  # ──────────────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    # Los flags del modal y de la edición sólo existen cuando `handle_params`
    # pasó por la rama que los administra: se normalizan para que el primer
    # render (y el de cualquier acción) siempre tenga el assign.
    assigns =
      assigns
      |> assign(modal_open: Map.get(assigns, :modal_open, false))
      |> assign(editing: Map.get(assigns, :editing, false))
      |> assign(workspace_id: Map.get(assigns, :workspace_id, nil))

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_user={@current_user}
      user={@user}
      workspace_slug={@workspace_slug}
      active_nav={@active_nav}
    >
      <ShareDialog.share_dialog
        id="plan-share-dialog"
        open={@share_open || false}
        resource_type="plan"
        resource_id={@plan && @plan.id}
        shares={@shares || []}
        users={@share_users || []}
        groups={@share_groups || []}
      />

      <%!-- ── Index: la lista, con el estándar de pages (header, vacío y tarjeta). ── --%>
      <div :if={@live_action == :index} id="plans-index" class="p-6 overflow-y-auto w-full">
        <.resource_list_header
          title={gettext("Plans")}
          new_event="new_plan"
          new_id="plan-new"
          new_testid="new-plan-button"
        />

        <.resource_filters
          prefix="plans"
          status={@filters.status}
          statuses={Enum.map(@statuses, &{&1, status_label(&1)})}
          order={@filters.order}
          orders={order_options()}
          total={@plan_count}
        />

        <%!-- El vacío de la COLECCIÓN es el que ofrece crear; con un filtro
        puesto, el «sin resultados» lo dice la barra de filtros. --%>
        <.resource_empty_state
          :if={@plan_count == 0 && is_nil(@filters.status)}
          icon="hero-clipboard-document-list"
          title={gettext("No plans yet")}
          description={gettext("Lay out the ordered steps before you start.")}
          cta={gettext("Create Plan")}
          new_path={~p"/plans?new=true"}
        />

        <%!-- El contenedor del stream sigue montado (oculto si no hay nada): el
        estado vacío se decide por CONTADOR, no por colección — un stream no es
        enumerable y no soporta un `:if` de lista. --%>
        <div id="plans" phx-update="stream" class={["space-y-2", @plan_count == 0 && "hidden"]}>
          <div :for={{dom_id, {plan, progress}} <- @streams.plans} id={dom_id}>
            <.plan_card plan={plan} progress={progress} />
          </div>
        </div>
      </div>

      <%!-- ── Show: el detalle. Editar es `?edit=true` EN esta misma página. ── --%>
      <div :if={@live_action == :show && @plan} id="plan-detail" class="p-6 overflow-y-auto w-full">
        <.resource_header
          title={@plan.title}
          subtitle={@plan.summary}
          icon="hero-clipboard-document-list"
          back_href={~p"/plans"}
          back_label={gettext("Back")}
        >
          <:actions>
            <button
              :if={can_manage_scope?(@plan, @user)}
              id="plan-share"
              phx-click="open_share"
              class="btn btn-ghost btn-sm"
            >
              <.icon name="hero-share" class="size-4" /> {gettext("Share")}
            </button>
            <.link
              :if={@editing}
              patch={~p"/plans/#{@plan.id}"}
              id="plan-view"
              class="btn btn-ghost btn-sm"
            >
              <.icon name="hero-eye" class="size-4" /> {gettext("View")}
            </.link>
            <.link
              :if={not @editing}
              patch={~p"/plans/#{@plan.id}?edit=true"}
              id="plan-edit"
              class="btn btn-ghost btn-sm"
            >
              <.icon name="hero-pencil" class="size-4" /> {gettext("Edit")}
            </.link>
            <button
              id="plan-delete"
              phx-click="delete_plan"
              data-confirm={gettext("Delete this plan?")}
              class="btn btn-ghost btn-sm text-error"
            >
              <.icon name="hero-trash" class="size-4" /> {gettext("Delete")}
            </button>
          </:actions>
        </.resource_header>

        <div class="flex flex-wrap items-center gap-2 mb-4">
          <span class="inline-flex items-center gap-1 text-[11px] font-medium px-2 py-0.5 rounded-full bg-sky-100 text-sky-700">
            <.icon name="hero-clipboard-document-list" class="size-3" /> {gettext("Plan")}
          </span>
          <span class={["px-2 py-0.5 text-xs rounded-full", status_class(@plan.status)]}>
            {status_label(@plan.status)}
          </span>
          <.resource_visibility_pill visibility={@plan.visibility} id="plan-visibility-badge" />
        </div>

        <div class="flex flex-col lg:flex-row gap-6">
          <%!-- Columna principal: cuerpo (o el panel de edición) y los PASOS. El
          progreso NO vive acá: es el titular del aside, y el dato se pinta UNA
          vez. --%>
          <div class="flex-1 min-w-0 space-y-6">
            <%= if @editing do %>
              <div id="plan-edit-panel" class="surface-2 rounded-xl p-4">
                <%!-- El checklist del EDIT tiene su propia puerta (el editor del
                panel de pasos): el form de edición no lo pisa. --%>
                <.plan_form
                  form={@form}
                  workspace_id={@workspace_id}
                  statuses={@statuses}
                  editing={true}
                />
              </div>
            <% else %>
              <div
                :if={@plan.body != nil and @plan.body != ""}
                class="prose prose-base dark:prose-invert max-w-none"
              >
                {render_markdown(@plan.body, [])}
              </div>
            <% end %>

            <div class="surface-2 rounded-xl p-4">
              <h3 class="text-sm font-semibold mb-3 flex items-center gap-2">
                <.icon name="hero-list-bullet" class="size-4 text-primary" /> {gettext("Steps")}
                <span class="badge badge-sm badge-ghost">{@progress.total}</span>
              </h3>

              <p :if={@progress.total == 0} class="text-sm text-base-content/40 mb-4">
                {gettext("No steps yet.")}
              </p>

              <form
                id="plan-steps-form"
                phx-submit="save_checklist"
                class="border-t border-base-300 pt-4"
              >
                <h4 class="text-xs font-semibold text-base-content/60 mb-2">
                  {gettext("Add, remove or reorder steps")}
                </h4>
                <.checklist_editor id="plan-steps-detail" name="steps" value={@plan.checklist} />
                <div class="flex justify-end mt-3">
                  <button type="submit" id="plan-steps-save" class="btn btn-primary btn-sm">
                    {gettext("Save steps")}
                  </button>
                </div>
              </form>
            </div>
          </div>

          <%!-- Aside del molde: Progress (titular, sin chevron), Related pages y
          Metadata colapsado. Es el MISMO aside del detalle de página. --%>
          <aside id="plan-sidebar" class="lg:w-72 xl:w-80 shrink-0 space-y-4">
            <%!-- El progreso se DERIVA del checklist: tachar un paso lo mueve. --%>
            <div class="surface-2 rounded-lg p-4">
              <div class="flex items-center justify-between mb-2">
                <h3 class="text-sm font-semibold flex items-center gap-2">
                  <.icon name="hero-chart-bar" class="size-4 text-primary" /> {gettext("Progress")}
                </h3>
                <span id="plan-progress-count" class="text-sm text-base-content/70">
                  {@progress.done}/{@progress.total}
                </span>
              </div>
              <div id="plan-progress" data-done={@progress.done} data-total={@progress.total}>
                <div class="w-full bg-base-200 rounded-full h-2 overflow-hidden">
                  <div class="bg-primary h-2 rounded-full" style={"width: #{@progress.percent}%"}>
                  </div>
                </div>
              </div>
            </div>

            <%!-- Páginas relacionadas: relaciones reales primero y, si no hay
            ninguna, el fallback semántico — con la FUENTE declarada y el alta
            EXPLÍCITA (el picker). El panel va EMBEBIDO: el título lo pone la
            sección del aside y el badge de la fuente nunca se esconde. --%>
            <.sidebar_section
              id="plan-related-section"
              title={gettext("Related")}
              open
              body_class="mt-2"
            >
              <.related_panel
                id="plan-related"
                related={@related}
                candidates={@related_candidates}
                workspace={@context}
                embedded
              />
            </.sidebar_section>

            <%!-- Metadata: todo sale de la FILA del plan (sin migración). Los
            pasos se cuentan acá (cuántos son) y su avance vive en el bloque de
            progreso de arriba; el plan no declara actor ni versionado. --%>
            <.sidebar_section
              id="plan-metadata"
              title={gettext("Metadata")}
              body_class="divide-y divide-base-300/50 mt-2"
            >
              <div class="flex justify-between gap-2 py-2 text-sm">
                <span class="text-base-content/60">{gettext("Status")}</span>
                <span class="font-medium">{status_label(@plan.status)}</span>
              </div>
              <div :if={@plan.starts_on} class="flex justify-between gap-2 py-2 text-sm">
                <span class="text-base-content/60">{gettext("Starts on")}</span>
                <span>{format_date(@plan.starts_on)}</span>
              </div>
              <div :if={@plan.due_on} class="flex justify-between gap-2 py-2 text-sm">
                <span class="text-base-content/60">{gettext("Due on")}</span>
                <span>{format_date(@plan.due_on)}</span>
              </div>
              <div class="flex justify-between gap-2 py-2 text-sm">
                <span class="text-base-content/60">{gettext("Steps")}</span>
                <span>{ngettext("%{count} step", "%{count} steps", @progress.total,
                  count: @progress.total
                )}</span>
              </div>
              <div class="flex justify-between gap-2 py-2 text-sm">
                <span class="text-base-content/60">{gettext("Visibility")}</span>
                <span>{visibility_label(@plan.visibility)}</span>
              </div>
              <div class="flex justify-between gap-2 py-2 text-sm">
                <span class="text-base-content/60">{gettext("Owner")}</span>
                <span>{owner_label(@plan.owner_user_id)}</span>
              </div>
              <div class="flex justify-between gap-2 py-2 text-sm">
                <span class="text-base-content/60">{gettext("Updated")}</span>
                <span>{format_date(@plan.updated_at)}</span>
              </div>
            </.sidebar_section>
          </aside>
        </div>
      </div>

      <%!-- ── Alta: el MISMO modal de pages, abierto por estado de URL. ── --%>
      <.resource_modal
        :if={@modal_open}
        id="plan-resource-modal"
        title={gettext("New plan")}
        pill="PLAN"
        on_close="close_plan_modal"
        form_id="plan-form"
        submit_label={gettext("Create")}
        cancel_label={gettext("Cancel")}
      >
        <%!-- El destino del plan vive junto a la ✕: los radios apuntan al form
        del body con el atributo HTML `form` (el modal está fuera del `<form>`). --%>
        <:header>
          <.resource_scope_field
            form={@form}
            id="plan-visibility-picker"
            form_id="plan-form"
            compact
          />
        </:header>

        <.plan_form
          form={@form}
          workspace_id={@workspace_id}
          statuses={@statuses}
          checklist={@checklist}
          with_scope={false}
        />
      </.resource_modal>
    </Layouts.app>
    """
  end

  attr :plan, :map, required: true
  attr :progress, :map, required: true

  defp plan_card(assigns) do
    ~H"""
    <.resource_card
      id={"plan-card-#{@plan.id}"}
      testid={"plan-card-#{@plan.id}"}
      icon="hero-clipboard-document-list"
      title={@plan.title}
      href={~p"/plans/#{@plan.id}"}
      badge={status_label(@plan.status)}
      badge_class={status_class(@plan.status)}
      summary={@plan.summary}
      progress={@progress}
      due_on={@plan.due_on}
      overdue?={overdue?(@plan)}
      visibility={@plan.visibility}
      visibility_always={true}
      meta={updated_meta(@plan.updated_at)}
    />
    """
  end

  # El form del plan es UNO: el alta lo monta dentro del modal de pages y la
  # edición en el panel del detalle (`?edit=true`). El editor de pasos SÓLO va
  # en el alta — en el detalle el checklist tiene su puerta (el panel de pasos).
  attr :form, :map, required: true
  attr :workspace_id, :string, default: nil
  attr :editing, :boolean, default: false
  attr :statuses, :list, required: true
  attr :checklist, :list, default: []

  attr :with_scope, :boolean,
    default: true,
    doc: "false cuando el modal ya muestra el destino en su header"

  defp plan_form(assigns) do
    ~H"""
    <.form for={@form} id="plan-form" phx-submit="save_plan" class="space-y-5">
      <.input field={@form[:title]} type="text" label={gettext("Title")} required />

      <%!-- Sin input de summary: es de la MÁQUINA (REST/augmentation/workers) —
      el form no lo pide y por eso editar desde acá nunca lo borra (el cast no
      toca lo que no viaja). Se LEE en el subtítulo del detalle y en la tarjeta. --%>

      <.markdown_body_field
        id="plan-editor"
        body={to_string(@form[:body].value || "")}
        workspace_id={@workspace_id}
        hidden_field="plan[body]"
        autosave={false}
        label={gettext("Body")}
      />

      <div class="grid grid-cols-2 gap-4">
        <.input
          field={@form[:status]}
          type="select"
          label={gettext("Status")}
          options={Enum.map(@statuses, &{&1, &1})}
        />
        <.input field={@form[:due_on]} type="date" label={gettext("Due on")} />
      </div>

      <%!-- El destino: el MISMO control que pages (private | public | shared).
      En el alta vive en el header del modal (`:header`), junto a la ✕; en la
      edición en página se queda acá. --%>
      <.resource_scope_field :if={@with_scope} form={@form} id="plan-visibility-picker" />

      <div :if={not @editing} class="border-t border-base-300 pt-5">
        <h3 class="text-sm font-semibold text-base-content/70 mb-3">{gettext("Steps")}</h3>
        <.checklist_editor id="plan-steps" name="steps" value={@checklist} />
        <p class="mt-1.5 text-xs leading-snug text-base-content/50">
          {gettext("Ordered steps. Checking one does not create a task.")}
        </p>
      </div>

      <%!-- El modal trae su propio footer (submit por `form_id`); la edición en
      página necesita su fila de acciones. --%>
      <.form_actions
        :if={@editing}
        submit_label={gettext("Save plan")}
        submit_icon="hero-check"
        cancel_event="cancel_plan_edit"
      />
    </.form>
    """
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Lifecycle
  # ──────────────────────────────────────────────────────────────────────────

  @impl true
  def mount(_params, session, socket) do
    {socket, context} = Auth.assign_to_socket(socket, session)

    {:ok,
     assign(socket,
       context: context,
       active_nav: "plans",
       statuses: @statuses,
       plan: nil,
       scope: nil,
       checklist: [],
       progress: %{done: 0, total: 0, percent: 0},
       form: new_plan_form(),
       share_open: false,
       shares: [],
       share_users: [],
       share_groups: [],
       modal_open: false,
       editing: false,
       plan_count: 0,
       filters: default_filters(),
       # Páginas relacionadas: la fuente y sus opciones. Sólo las llena el
       # detalle (`assign_related/2`).
       related: %{source: :none, pages: []},
       related_candidates: [],
       workspace_id: context && context.id
     )}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  # La lista: `?new=true` abre el modal del alta (estado de URL, no una ruta), y
  # `?status=`/`?order=` son los filtros — los mismos que el board y que /goals.
  defp apply_action(socket, :index, params) do
    modal_open = params["new"] == "true"

    case reader_scope(socket) do
      nil ->
        push_navigate(socket, to: ~p"/")

      scope ->
        filters = filters_from(params)

        plans =
          Plans.list_plans(scope: scope, status: filters.status, order: filters.order)
          |> Enum.map(&{&1, Plans.progress(&1)})

        socket
        |> assign(
          page_title: gettext("Plans"),
          scope: scope,
          modal_open: modal_open,
          filters: filters,
          plan_count: length(plans),
          workspace_id: workspace_id(socket),
          checklist: if(modal_open, do: [], else: socket.assigns[:checklist]),
          form: if(modal_open, do: new_plan_form(), else: socket.assigns[:form])
        )
        |> stream(:plans, plans,
          reset: true,
          dom_id: fn {plan, _progress} -> "plan-#{plan.id}" end
        )
    end
  end

  # El detalle: `?edit=true` edita EN la página (patch), sin ruta `/edit`.
  defp apply_action(socket, :show, %{"id" => id_or_slug} = params) do
    case reader_scope(socket) do
      nil ->
        push_navigate(socket, to: ~p"/")

      scope ->
        case fetch_plan(id_or_slug, scope) do
          nil ->
            push_navigate(socket, to: ~p"/plans")

          plan ->
            editing = params["edit"] == "true"

            socket
            |> assign(
              plan: plan,
              scope: scope,
              editing: editing,
              progress: Plans.progress(plan),
              checklist: plan.checklist,
              page_title: plan.title,
              workspace_id: workspace_id(socket),
              form:
                if(editing,
                  do: to_form(Plans.change_plan(plan, %{})),
                  else: socket.assigns[:form]
                )
            )
            |> assign_related(plan)
        end
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Events
  # ──────────────────────────────────────────────────────────────────────────

  # Abrir/cerrar el alta es URL state: `push_patch` (el LiveView no se remonta y
  # el stream de la lista sobrevive). Nunca `push_navigate`. Los filtros vigentes
  # viajan en el patch: abrir el alta no los borra.
  @impl true
  def handle_event("new_plan", _params, socket),
    do:
      {:noreply,
       push_patch(socket, to: plans_path(current_query(socket) |> Map.put("new", "true")))}

  def handle_event("close_plan_modal", _params, socket),
    do: {:noreply, push_patch(socket, to: plans_path(current_query(socket)))}

  # Los filtros viven en la URL: cambiar uno es un patch, no un assign suelto
  # (el mismo molde que los filtros del board y que /goals).
  def handle_event("filter", params, socket) do
    query =
      current_query(socket)
      |> Map.put("status", params["status"])
      |> Map.put("order", params["order"])

    {:noreply, push_patch(socket, to: plans_path(query))}
  end

  def handle_event("cancel_plan_edit", _params, %{assigns: %{plan: %Plan{} = plan}} = socket),
    do: {:noreply, push_patch(socket, to: ~p"/plans/#{plan.id}")}

  def handle_event("cancel_plan_edit", _params, socket), do: {:noreply, socket}

  def handle_event("save_plan", %{"plan" => params} = all, socket) do
    case socket.assigns[:plan] do
      nil ->
        params
        |> Map.put("checklist", Dran.Checklist.cast(all["steps"]))
        |> Map.merge(owner_attrs(socket))
        |> Plans.create_plan()
        |> plan_form_result(socket)

      %Plan{} = plan ->
        # El slug se auto-administra por el contexto; el checklist del EDIT
        # tiene su propia puerta en el detalle (no se pisa desde el form).
        plan
        |> Plans.update_plan(Map.merge(params, owner_attrs(socket)))
        |> plan_form_result(socket)
    end
  end

  def handle_event("delete_plan", _params, %{assigns: %{plan: %Plan{} = plan}} = socket) do
    {:ok, _} = Plans.delete_plan(plan)

    {:noreply,
     socket
     |> put_flash(:info, gettext("Plan deleted."))
     |> push_navigate(to: ~p"/plans")}
  end

  def handle_event("delete_plan", _params, socket), do: {:noreply, socket}

  def handle_event("save_checklist", params, %{assigns: %{plan: %Plan{} = plan}} = socket) do
    steps = Dran.Checklist.cast(params["steps"])

    case Plans.set_checklist(plan, steps, lock_version: plan.lock_version) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(plan: updated, progress: Plans.progress(updated), checklist: updated.checklist)
         |> put_flash(:info, gettext("Steps saved."))}

      {:error, :stale} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("The plan changed elsewhere — reloading."))
         |> reload_plan()}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, gettext("Could not save the steps."))}
    end
  end

  def handle_event("save_checklist", _params, socket), do: {:noreply, socket}

  def handle_event("open_share", _params, %{assigns: %{plan: %Plan{} = plan}} = socket) do
    {:noreply,
     socket
     |> assign(:share_open, true)
     |> assign(:shares, Dran.Sharing.list_shares("plan", plan.id))
     |> assign(:share_users, Dran.Accounts.list_users())
     |> assign(:share_groups, Dran.Sharing.list_groups())}
  end

  def handle_event("open_share", _params, socket), do: {:noreply, socket}

  def handle_event("close_share", _params, socket),
    do: {:noreply, assign(socket, :share_open, false)}

  def handle_event("noop", _params, socket), do: {:noreply, socket}

  # El alta de una relación desde el sidebar: EXPLÍCITA (el picker), atribuida a
  # quien la crea y sólo sobre una página que el lector puede leer.
  def handle_event(
        "link_related",
        %{"page_id" => page_id},
        %{assigns: %{plan: %Plan{} = plan}} = socket
      )
      when page_id != "" do
    scope = Dran.ContentVisibility.personal_scope(socket.assigns[:user])

    case Dran.Related.link("plan", plan, page_id, socket.assigns[:user],
           scope: scope,
           workspace_id: workspace_id(socket)
         ) do
      {:ok, _relation} ->
        {:noreply,
         socket
         |> assign_related(plan)
         |> put_flash(:info, gettext("Page linked."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not link that page."))}
    end
  end

  def handle_event("link_related", _params, socket), do: {:noreply, socket}

  def handle_event("share_with_user", %{"user_id" => user_id}, %{assigns: %{plan: plan}} = socket)
      when user_id != "" and not is_nil(plan) do
    case Dran.Sharing.grant(plan, :plan, {:user, String.to_integer(user_id)}) do
      {:ok, :shared, updated} ->
        {:noreply,
         socket
         |> assign(plan: updated, shares: Dran.Sharing.list_shares("plan", plan.id))
         |> put_flash(:info, gettext("Shared."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not share."))}
    end
  end

  def handle_event("share_with_user", _params, socket), do: {:noreply, socket}

  def handle_event(
        "share_with_group",
        %{"group_id" => group_id},
        %{assigns: %{plan: plan}} = socket
      )
      when group_id != "" and not is_nil(plan) do
    case Dran.Sharing.grant(plan, :plan, {:group, String.to_integer(group_id)}) do
      {:ok, :shared, updated} ->
        {:noreply,
         socket
         |> assign(plan: updated, shares: Dran.Sharing.list_shares("plan", plan.id))
         |> put_flash(:info, gettext("Shared."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not share."))}
    end
  end

  def handle_event("share_with_group", _params, socket), do: {:noreply, socket}

  def handle_event("unshare", %{"id" => share_id}, %{assigns: %{plan: plan}} = socket)
      when not is_nil(plan) do
    :ok = Dran.Sharing.unshare(share_id)
    {:noreply, assign(socket, :shares, Dran.Sharing.list_shares("plan", plan.id))}
  end

  def handle_event("unshare", _params, socket), do: {:noreply, socket}

  # ──────────────────────────────────────────────────────────────────────────
  # Helpers
  # ──────────────────────────────────────────────────────────────────────────

  # Las páginas relacionadas del plan: las relaciones REALES del grafo primero
  # y, SÓLO si no hay ninguna, el fallback semántico (`Dran.Related`). Lee con
  # la puerta PERSONAL (un owner/admin no ensancha acá) y el alta es el picker.
  defp assign_related(socket, plan) do
    scope = Dran.ContentVisibility.personal_scope(socket.assigns[:user])
    opts = [scope: scope, workspace_id: workspace_id(socket)]

    assign(socket,
      related: Dran.Related.for_entity("plan", plan, opts),
      related_candidates: Dran.Related.linkable_pages("plan", plan, opts)
    )
  end

  defp new_plan_form do
    to_form(Plans.change_plan(%Plan{}, %{"status" => "draft", "visibility" => "private"}))
  end

  # El resultado del form del plan: el alta navega al detalle recién creado y la
  # edición sale del modo edición con un patch (el detalle no se remonta).
  defp plan_form_result({:ok, plan}, socket) do
    socket =
      socket
      |> put_flash(:info, gettext("Plan saved."))
      |> assign(plan: plan, progress: Plans.progress(plan), checklist: plan.checklist)

    if socket.assigns[:editing] do
      {:noreply, push_patch(socket, to: ~p"/plans/#{plan.id}")}
    else
      {:noreply, push_navigate(socket, to: ~p"/plans/#{plan.id}")}
    end
  end

  defp plan_form_result({:error, %Ecto.Changeset{} = changeset}, socket),
    do: {:noreply, assign(socket, form: to_form(changeset))}

  # El workspace del editor de markdown (wikilinks y uploads), tal como lo pasa
  # pages: el id del contexto, nil si aún no se resolvió.
  defp workspace_id(socket) do
    case socket.assigns[:context] do
      nil -> nil
      context -> context.id
    end
  end

  defp reload_plan(socket) do
    case {socket.assigns[:plan], socket.assigns[:scope]} do
      {%Plan{id: id}, scope} when not is_nil(scope) ->
        case Plans.get_plan(id, scope: scope) do
          nil ->
            socket

          plan ->
            assign(socket, plan: plan, progress: Plans.progress(plan), checklist: plan.checklist)
        end

      _ ->
        socket
    end
  end

  # El destino lo administra quien puede escribir: el DUEÑO (constraint 8). El
  # diálogo agrega y quita grants; compartir fija `shared` en la misma operación.
  # La regla es UNA para todas las secciones: `can_manage_scope?/2` de
  # `DranWeb.ResourceComponents` (acá vivía copiada).

  # El dueño del plan para el bloque Metadata del aside: la tabla guarda el id
  # (`owner_user_id`) y NULL es contenido de sistema. Se pinta el NOMBRE de la
  # cuenta, nunca el id crudo (C11) — el plan no declara actor ni versionado.
  defp owner_label(nil), do: gettext("Instance")

  defp owner_label(user_id) when is_integer(user_id) do
    case Accounts.get_user(user_id) do
      nil -> gettext("Unknown")
      user -> user.name || user.email
    end
  end

  defp owner_label(_other), do: gettext("Unknown")

  defp reader_scope(socket) do
    case socket.assigns[:user] do
      nil -> nil
      user -> Dran.ContentVisibility.resolve(socket.assigns[:context], user, :plan)
    end
  end

  defp owner_attrs(socket) do
    case Dran.Auth.resolve_owner_user_id(socket.assigns[:user]) do
      nil -> %{}
      user_id -> %{"owner_user_id" => user_id}
    end
  end

  defp fetch_plan(id_or_slug, scope) do
    case cast_uuid(id_or_slug) do
      {:ok, uuid} -> Plans.get_plan(uuid, scope: scope)
      :error -> Plans.get_plan_by_slug(id_or_slug, scope: scope)
    end
  end

  defp cast_uuid(value) when is_binary(value) do
    if byte_size(value) == 36, do: Ecto.UUID.cast(value), else: :error
  end

  defp cast_uuid(_), do: :error

  # ── Los filtros del índice ────────────────────────────────────────────────

  defp default_filters, do: %{status: nil, order: @default_order}

  # Los filtros viven en la URL: lo que no está en el vocabulario se DESCARTA
  # (un `?status=<basura>` forjado no filtra ni rompe), y un `?order=` ausente
  # cae al default.
  defp filters_from(params) do
    %{
      status: (params["status"] in @statuses && params["status"]) || nil,
      order: (params["order"] in Dran.ListOrder.orders() && params["order"]) || @default_order
    }
  end

  # La query vigente del índice: es lo que se arrastra al abrir el alta y lo que
  # hace compartible un filtro.
  defp current_query(socket) do
    %{
      "status" => socket.assigns.filters.status,
      "order" => socket.assigns.filters.order,
      "new" => nil
    }
  end

  # La URL del índice con su query. Campos en orden FIJO y fuera lo vacío y el
  # orden default (`?order=due` no aparece nunca): la URL es estable y un test
  # la puede afirmar entera — el mismo molde que `board_path/2`.
  @query_fields ~w(status order new)

  defp plans_path(query) do
    pairs =
      for field <- @query_fields,
          value = query[field],
          value not in [nil, ""],
          not (field == "order" and value == @default_order),
          do: {field, value}

    case URI.encode_query(pairs) do
      "" -> "/plans"
      qs -> "/plans?" <> qs
    end
  end
end
