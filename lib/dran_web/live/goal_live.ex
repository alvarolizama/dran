defmodule DranWeb.GoalLive do
  @moduledoc """
  El contenedor de trabajo en la web: lista, detalle y —desde el contrato de
  superficies— **crear, editar y borrar** goals, más la captura de tasks.

  La UI sigue la ESTRUCTURA de pages (contrato de paridad UI/UX): el alta vive
  en un `<.resource_modal>` abierto por estado de URL (`?new=true`) y la edición
  ocurre EN el detalle con `?edit=true` — no existen las rutas `/goals/new` ni
  `/goals/:id/edit`. El shell, el header y las acciones son los componentes
  compartidos (`DranWeb.ResourceComponents`) y el body se edita con el editor de
  markdown de pages (`markdown_body_field`), no con un textarea propio.

  * la LECTURA pasa por los contextos con `scope:` resuelto por la política
    única (`Dran.ContentVisibility`): un goal ajeno privado no se abre (navega
    fuera) y una sesión sin fila en `users` tampoco (Constraint 4);
  * la ESCRITURA sella al autor como dueño (`owner_attrs/1`, Constraint 3) —el
    dueño nunca viene del formulario— y el destino lo elige la UI con
    `visibility` (private | public | shared; Constraint 5), cuyos grants se
    administran con el diálogo de compartir (los shares otorgan sólo lectura);
  * el progreso se DERIVA de las tasks y nunca se guarda.
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
      visibility_label: 1,
      horizon_label: 1
    ]

  alias Dran.{Accounts, Goals, Sharing, Tasks}
  alias Dran.Goals.Goal
  alias Dran.Tasks.Task
  alias DranWeb.Components.ShareDialog
  alias DranWeb.Plugs.Auth

  @horizons ~w(someday day week month quarter year)
  @statuses ~w(draft active on_hold done archived)

  # El orden del listado por default: «por vencer» es lo accionable en un índice
  # de objetivos. La URL lo OMITE (no hay `?order=due`), como los filtros del
  # board omiten lo vacío.
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
      |> assign(task_modal_open: Map.get(assigns, :task_modal_open, false))
      |> assign(task_groups: Map.get(assigns, :task_groups, []))
      |> assign(editing_task: Map.get(assigns, :editing_task, nil))

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
        id="goal-share-dialog"
        open={@share_open || false}
        resource_type="goal"
        resource_id={@goal && @goal.id}
        shares={@shares || []}
        users={@share_users || []}
        groups={@share_groups || []}
      />

      <%!-- ── Index: la lista, con el estándar de pages (header, vacío y tarjeta). ── --%>
      <div :if={@live_action == :index} id="goals-index" class="p-6 overflow-y-auto w-full">
        <.resource_list_header
          title={gettext("Goals")}
          new_event="new_goal"
          new_id="goal-new"
          new_testid="new-goal-button"
        />

        <.resource_filters
          prefix="goals"
          status={@filters.status}
          statuses={Enum.map(@statuses, &{&1, status_label(&1)})}
          order={@filters.order}
          orders={order_options()}
          total={@goal_count}
        />

        <%!-- El vacío de la COLECCIÓN es el que ofrece crear; con un filtro
        puesto, el «sin resultados» lo dice la barra de filtros. --%>
        <.resource_empty_state
          :if={@goal_count == 0 && is_nil(@filters.status)}
          icon="hero-flag"
          title={gettext("No goals yet")}
          description={gettext("Track what you are working toward and the tasks that get you there.")}
          cta={gettext("Create Goal")}
          new_path={~p"/goals?new=true"}
        />

        <%!-- El contenedor del stream sigue montado (oculto si no hay nada): el
        estado vacío se decide por CONTADOR, no por colección — un stream no es
        enumerable y no soporta un `:if` de lista. --%>
        <div id="goals" phx-update="stream" class={["space-y-2", @goal_count == 0 && "hidden"]}>
          <div :for={{dom_id, {goal, progress}} <- @streams.goals} id={dom_id}>
            <.goal_card goal={goal} progress={progress} />
          </div>
        </div>
      </div>

      <%!-- ── Show: el detalle. Editar es `?edit=true` EN esta misma página. ── --%>
      <div :if={@live_action == :show && @goal} id="goal-detail" class="p-6 overflow-y-auto w-full">
        <.resource_header
          title={@goal.title}
          subtitle={@goal.summary}
          icon="hero-flag"
          back_href={~p"/goals"}
          back_label={gettext("Back")}
        >
          <:actions>
            <button
              :if={can_manage_scope?(@goal, @user)}
              id="goal-share"
              phx-click="open_share"
              class="btn btn-ghost btn-sm"
            >
              <.icon name="hero-share" class="size-4" /> {gettext("Share")}
            </button>
            <.link
              :if={@editing}
              patch={~p"/goals/#{@goal.id}"}
              id="goal-view"
              class="btn btn-ghost btn-sm"
            >
              <.icon name="hero-eye" class="size-4" /> {gettext("View")}
            </.link>
            <.link
              :if={not @editing}
              patch={~p"/goals/#{@goal.id}?edit=true"}
              id="goal-edit"
              class="btn btn-ghost btn-sm"
            >
              <.icon name="hero-pencil" class="size-4" /> {gettext("Edit")}
            </.link>
            <button
              id="goal-delete"
              phx-click="delete_goal"
              data-confirm={gettext("Delete this goal and all its tasks?")}
              class="btn btn-ghost btn-sm text-error"
            >
              <.icon name="hero-trash" class="size-4" /> {gettext("Delete")}
            </button>
            <.link
              navigate={~p"/tasks/#{@goal.id}"}
              id="goal-open-board"
              class="btn btn-ghost btn-sm"
            >
              <.icon name="hero-view-columns" class="size-4" /> {gettext("Board")}
            </.link>
          </:actions>
        </.resource_header>

        <div class="flex flex-wrap items-center gap-2 mb-4">
          <span class="inline-flex items-center gap-1 text-[11px] font-medium px-2 py-0.5 rounded-full bg-green-100 text-green-700">
            <.icon name="hero-flag" class="size-3" /> {gettext("Goal")}
          </span>
          <span class={["px-2 py-0.5 text-xs rounded-full", status_class(@goal.status)]}>
            {status_label(@goal.status)}
          </span>
          <span
            :if={@goal.horizon}
            class="px-2 py-0.5 text-xs rounded-full bg-base-200 text-base-content/70"
          >
            {@goal.horizon}
          </span>
          <.resource_visibility_pill visibility={@goal.visibility} id="goal-visibility-badge" />
        </div>

        <%= if @editing do %>
          <div id="goal-edit-panel" class="surface-2 rounded-xl p-4">
            <.goal_form
              form={@form}
              workspace_id={@workspace_id}
              statuses={@statuses}
              horizons={@horizons}
              editing={true}
            />
          </div>
        <% else %>
          <div class="flex flex-col lg:flex-row gap-6">
            <%!-- Columna principal: cuerpo, subgoals y tasks. El progreso NO vive
            acá: es el titular del aside (abajo), y el dato se pinta UNA vez. --%>
            <div class="flex-1 min-w-0 space-y-6">
              <div
                :if={@goal.body != nil and @goal.body != ""}
                class="prose prose-base dark:prose-invert max-w-none"
              >
                {render_markdown(@goal.body, [])}
              </div>

              <div :if={@children != []} class="surface-2 rounded-xl p-4">
                <h3 class="text-sm font-semibold mb-3 flex items-center gap-2">
                  <.icon name="hero-flag" class="size-4 text-primary" /> {gettext("Subgoals")}
                  <span class="badge badge-sm badge-ghost">{length(@children)}</span>
                </h3>
                <ul id="goal-children" class="space-y-1.5">
                  <li :for={child <- @children} id={"goal-child-#{child.id}"}>
                    <.link
                      navigate={~p"/goals/#{child.id}"}
                      class="flex items-center gap-2 text-sm py-1.5 px-2 rounded-lg hover:bg-base-200/60 transition"
                    >
                      <.icon name="hero-flag" class="size-4 shrink-0 text-base-content/40" />
                      <span class="flex-1 min-w-0 truncate">{child.title}</span>
                    </.link>
                  </li>
                </ul>
              </div>

              <div class="surface-2 rounded-xl p-4">
                <div class="flex items-center justify-between mb-3">
                  <h3 class="text-sm font-semibold flex items-center gap-2">
                    <.icon name="hero-check-circle" class="size-4 text-primary" /> {gettext("Tasks")}
                    <span class="badge badge-sm badge-ghost">{@task_count}</span>
                  </h3>
                  <div class="flex items-center gap-2">
                    <button
                      type="button"
                      id="goal-task-new"
                      phx-click="new_task"
                      class="btn btn-primary btn-xs"
                    >
                      <.icon name="hero-plus" class="size-3.5" /> {gettext("New task")}
                    </button>
                    <.link
                      navigate={~p"/tasks/#{@goal.id}"}
                      class="text-xs text-base-content/60 hover:underline"
                    >
                      {gettext("Open board")}
                    </.link>
                  </div>
                </div>

                <p :if={@task_count == 0} class="text-sm text-base-content/40 py-2">
                  {gettext("No tasks yet.")}
                </p>

                <%!-- Agrupadas por STATUS: el estado se VE en el encabezado y se
              CAMBIA por la única puerta del dominio (Tasks.move_task/2). --%>
                <div :for={{status, tasks} <- @task_groups} class="mb-3 last:mb-0">
                  <h4 class="text-xs font-semibold uppercase tracking-wider text-base-content/50 mb-1.5 flex items-center gap-1.5">
                    <span class={["size-2 rounded-full shrink-0", dot_class(status)]} />
                    {task_status_label(status)}
                    <span class="badge badge-xs badge-ghost">{length(tasks)}</span>
                  </h4>

                  <div class="space-y-1.5">
                    <div
                      :for={task <- tasks}
                      id={"tasks-#{task.id}"}
                      data-status={task.status}
                      class="rounded-lg bg-base-100 border border-base-300 p-2 space-y-1.5"
                    >
                      <div class="flex items-center gap-2 text-sm">
                        <span class={[
                          "flex-1 min-w-0 truncate",
                          task.status in ~w(done cancelled) && "line-through text-base-content/40"
                        ]}>
                          {task.title}
                        </span>
                        <span :if={task.due_date} class="shrink-0 text-xs text-base-content/50">
                          {Calendar.strftime(task.due_date, "%d %b")}
                        </span>
                      </div>

                      <%!-- El estado NO se cambia acá: la lista no lleva select. Se
                    ve en el encabezado de su grupo y se cambia en el modal de
                    edición (mismos campos que el alta). --%>
                      <div class="flex items-center gap-2">
                        <button
                          type="button"
                          id={"goal-task-edit-#{task.id}"}
                          phx-click="edit_task"
                          phx-value-task_id={task.id}
                          class="text-xs text-base-content/50 hover:text-base-content/80"
                        >
                          {gettext("Edit")}
                        </button>
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            </div>

            <%!-- Aside del molde: Progress (titular, sin chevron), Related pages y
            Metadata colapsado. Es el MISMO aside del detalle de página. --%>
            <aside id="goal-sidebar" class="lg:w-72 xl:w-80 shrink-0 space-y-4">
              <%!-- Progreso DERIVADO de las tasks: nunca un campo guardado. --%>
              <div class="surface-2 rounded-lg p-4">
                <h3 class="text-sm font-semibold mb-2 flex items-center gap-2">
                  <.icon name="hero-chart-bar" class="size-4 text-primary" /> {gettext("Progress")}
                </h3>
                <div id="goal-progress" data-done={@progress.done} data-total={@progress.total}>
                  <div class="flex items-center justify-between text-sm mb-1">
                    <span class="text-base-content/70">{gettext("Done")}</span>
                    <span class="font-medium">{@progress.done}/{@progress.total}</span>
                  </div>
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
                id="goal-related-section"
                title={gettext("Related")}
                open
                body_class="mt-2"
              >
                <.related_panel
                  id="goal-related"
                  related={@related}
                  candidates={@related_candidates}
                  workspace={@context}
                  embedded
                />
              </.sidebar_section>

              <%!-- Metadata: todo sale de la FILA del goal (sin migración). Lo que
              el molde de pages muestra como «Created by / Version» no existe acá:
              goals no tienen actor ni versionado — el dueño y el updated_at son
              los que la tabla sí declara. --%>
              <.sidebar_section
                id="goal-metadata"
                title={gettext("Metadata")}
                body_class="divide-y divide-base-300/50 mt-2"
              >
                <div class="flex justify-between gap-2 py-2 text-sm">
                  <span class="text-base-content/60">{gettext("Status")}</span>
                  <span class="font-medium">{status_label(@goal.status)}</span>
                </div>
                <div :if={@goal.horizon} class="flex justify-between gap-2 py-2 text-sm">
                  <span class="text-base-content/60">{gettext("Horizon")}</span>
                  <span>{horizon_label(@goal.horizon)}</span>
                </div>
                <div :if={@goal.starts_on} class="flex justify-between gap-2 py-2 text-sm">
                  <span class="text-base-content/60">{gettext("Starts on")}</span>
                  <span>{format_date(@goal.starts_on)}</span>
                </div>
                <div :if={@goal.due_on} class="flex justify-between gap-2 py-2 text-sm">
                  <span class="text-base-content/60">{gettext("Due on")}</span>
                  <span>{format_date(@goal.due_on)}</span>
                </div>
                <div class="flex justify-between gap-2 py-2 text-sm">
                  <span class="text-base-content/60">{gettext("Visibility")}</span>
                  <span>{visibility_label(@goal.visibility)}</span>
                </div>
                <div class="flex justify-between gap-2 py-2 text-sm">
                  <span class="text-base-content/60">{gettext("Owner")}</span>
                  <span>{owner_label(@goal.owner_user_id)}</span>
                </div>
                <div class="flex justify-between gap-2 py-2 text-sm">
                  <span class="text-base-content/60">{gettext("Updated")}</span>
                  <span>{format_date(@goal.updated_at)}</span>
                </div>
              </.sidebar_section>
            </aside>
          </div>
        <% end %>
      </div>

      <%!-- ── Alta: el MISMO modal de pages, abierto por estado de URL. ── --%>
      <.resource_modal
        :if={@modal_open}
        id="goal-resource-modal"
        title={gettext("New goal")}
        pill="GOAL"
        on_close="close_goal_modal"
        form_id="goal-form"
        submit_label={gettext("Create")}
        cancel_label={gettext("Cancel")}
      >
        <%!-- El destino del goal vive junto a la ✕: los radios apuntan al form del
        body con el atributo HTML `form` (el modal está fuera del `<form>`). --%>
        <:header>
          <.resource_scope_field
            form={@form}
            id="goal-visibility-picker"
            form_id="goal-form"
            compact
          />
        </:header>

        <.goal_form
          form={@form}
          workspace_id={@workspace_id}
          statuses={@statuses}
          horizons={@horizons}
          with_scope={false}
        />
      </.resource_modal>
      <%!-- ── Alta y edición de una TASK: el MISMO modal en el board y acá
      (`DranWeb.TaskComponents`). El detalle ya tiene su goal (es la ruta), así
      que no hay selector de contenedor: la task nace en ESTE goal. ── --%>
      <.task_modal
        :if={@task_modal_open}
        id="task-resource-modal"
        title={gettext("New task")}
        on_close="close_task_modal"
        form_id="goal-task-form"
        prefix="goal-task"
        submit="add_task"
        submit_label={gettext("Create")}
        form={@task_form}
        workspace_id={@workspace_id}
        statuses={task_status_options()}
        priorities={priority_options()}
      />

      <%!-- Editar una task: el modal del molde, con los pasos y el borrado —
      exactamente el mismo que el del board. --%>
      <.task_modal
        :if={@editing_task}
        id="goal-task-edit-modal"
        title={gettext("Edit task")}
        on_close="close_edit_modal"
        form_id={"goal-task-edit-form-#{@editing_task.id}"}
        prefix={"goal-task-edit-#{@editing_task.id}"}
        submit="update_task"
        submit_label={gettext("Save")}
        form={@task_edit_form}
        workspace_id={@workspace_id}
        task={@editing_task}
        checklist={@editing_task.checklist}
        on_delete="delete_task"
        statuses={task_status_options()}
        priorities={priority_options()}
      />
    </Layouts.app>
    """
  end

  attr :goal, :map, required: true
  attr :progress, :map, required: true

  defp goal_card(assigns) do
    ~H"""
    <.resource_card
      id={"goal-card-#{@goal.id}"}
      testid={"goal-card-#{@goal.id}"}
      icon="hero-flag"
      title={@goal.title}
      href={~p"/goals/#{@goal.id}"}
      badge={status_label(@goal.status)}
      badge_class={status_class(@goal.status)}
      summary={@goal.summary}
      progress={@progress}
      due_on={@goal.due_on}
      overdue?={overdue?(@goal)}
      visibility={@goal.visibility}
      meta={updated_meta(@goal.updated_at)}
    >
      <%!-- El horizonte es de goal (el plan no lo tiene): entra como ficha
      extra del molde, con el mismo estilo que progreso/vencimiento. --%>
      <:footer>
        <span
          :if={@goal.horizon}
          class="inline-flex items-center gap-1 text-[11px] font-medium px-2 py-0.5 rounded-full bg-base-300/60 text-base-content/60"
        >
          <.icon name="hero-sun" class="size-3" /> {@goal.horizon}
        </span>
      </:footer>
    </.resource_card>
    """
  end

  # El form del goal es UNO: el alta lo monta dentro del modal de pages y la
  # edición en el panel del detalle (`?edit=true`). Los campos de metadatos y el
  # editor de body son los del molde de pages.
  attr :form, :map, required: true
  attr :workspace_id, :string, default: nil
  attr :editing, :boolean, default: false
  attr :statuses, :list, required: true
  attr :horizons, :list, required: true

  attr :with_scope, :boolean,
    default: true,
    doc: "false cuando el modal ya muestra el destino en su header"

  defp goal_form(assigns) do
    ~H"""
    <.form for={@form} id="goal-form" phx-submit="save_goal" class="space-y-5">
      <.input field={@form[:title]} type="text" label={gettext("Title")} required />

      <%!-- Sin input de summary: es de la MÁQUINA (REST/augmentation/workers) —
      el form no lo pide y por eso editar desde acá nunca lo borra (el cast no
      toca lo que no viaja). Se LEE en el subtítulo del detalle y en la tarjeta. --%>

      <.markdown_body_field
        id="goal-editor"
        body={to_string(@form[:body].value || "")}
        workspace_id={@workspace_id}
        hidden_field="goal[body]"
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
        <.input
          field={@form[:horizon]}
          type="select"
          label={gettext("Horizon")}
          prompt={gettext("None")}
          options={Enum.map(@horizons, &{&1, &1})}
        />
        <.input field={@form[:starts_on]} type="date" label={gettext("Starts on")} />
        <.input field={@form[:due_on]} type="date" label={gettext("Due on")} />
      </div>

      <%!-- El destino: el MISMO control que pages (private | public | shared).
      En el alta vive en el header del modal (`:header`), junto a la ✕; en la
      edición en página se queda acá. --%>
      <.resource_scope_field :if={@with_scope} form={@form} id="goal-visibility-picker" />

      <%!-- El modal trae su propio footer (submit por `form_id`); la edición en
      página necesita su fila de acciones. --%>
      <.form_actions
        :if={@editing}
        submit_label={gettext("Save goal")}
        submit_icon="hero-check"
        cancel_event="cancel_goal_edit"
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
       active_nav: "goals",
       statuses: @statuses,
       horizons: @horizons,
       goal: nil,
       scope: nil,
       progress: empty_progress(),
       children: [],
       task_count: 0,
       task_groups: [],
       # Páginas relacionadas: la fuente y sus opciones. Sólo las llena el
       # detalle (`assign_related/2`).
       related: %{source: :none, pages: []},
       related_candidates: [],
       task_modal_open: false,
       editing_task: nil,
       task_edit_form: new_task_form(),
       form: new_goal_form(),
       task_form: to_form(%{}, as: :task),
       share_open: false,
       shares: [],
       share_users: [],
       share_groups: [],
       modal_open: false,
       editing: false,
       goal_count: 0,
       filters: default_filters(),
       workspace_id: context && context.id
     )}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  # La lista: `?new=true` abre el modal del alta (estado de URL, no una ruta), y
  # `?status=`/`?order=` son los filtros — los mismos que el board, en la URL.
  defp apply_action(socket, :index, params) do
    modal_open = params["new"] == "true"

    case reader_scope(socket) do
      nil ->
        push_navigate(socket, to: ~p"/")

      scope ->
        filters = filters_from(params)

        goals = Goals.list_goals(scope: scope, status: filters.status, order: filters.order)
        progress = Goals.progress_map(goals)

        socket
        |> assign(
          page_title: gettext("Goals"),
          scope: scope,
          modal_open: modal_open,
          filters: filters,
          goal_count: length(goals),
          workspace_id: workspace_id(socket),
          form: if(modal_open, do: new_goal_form(), else: socket.assigns[:form])
        )
        |> stream(:goals, Enum.map(goals, &{&1, Map.fetch!(progress, &1.id)}),
          reset: true,
          dom_id: fn {goal, _progress} -> "goal-#{goal.id}" end
        )
    end
  end

  # El detalle: `?edit=true` edita EN la página (patch), sin ruta `/edit`.
  defp apply_action(socket, :show, %{"id" => id_or_slug} = params) do
    case reader_scope(socket) do
      nil ->
        push_navigate(socket, to: ~p"/")

      scope ->
        case fetch_goal(id_or_slug, scope) do
          nil ->
            push_navigate(socket, to: ~p"/goals")

          goal ->
            editing = params["edit"] == "true"

            socket
            |> assign(
              goal: goal,
              scope: scope,
              editing: editing,
              progress: Goals.progress(goal),
              children: Goals.list_children(goal, scope: scope),
              page_title: goal.title,
              workspace_id: workspace_id(socket),
              form:
                if(editing,
                  do: to_form(Goals.change_goal(goal, %{})),
                  else: socket.assigns[:form]
                ),
              task_modal_open: params["new_task"] == "true",
              editing_task: nil,
              task_form: new_task_form()
            )
            |> assign_related(goal)
            |> reload_tasks(scope)
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
  def handle_event("new_goal", _params, socket),
    do:
      {:noreply,
       push_patch(socket, to: goals_path(current_query(socket) |> Map.put("new", "true")))}

  def handle_event("close_goal_modal", _params, socket),
    do: {:noreply, push_patch(socket, to: goals_path(current_query(socket)))}

  # Los filtros viven en la URL: cambiar uno es un patch, no un assign suelto
  # (el mismo molde que los filtros del board).
  def handle_event("filter", params, socket) do
    query =
      current_query(socket)
      |> Map.put("status", params["status"])
      |> Map.put("order", params["order"])

    {:noreply, push_patch(socket, to: goals_path(query))}
  end

  def handle_event("cancel_goal_edit", _params, %{assigns: %{goal: %Goal{} = goal}} = socket),
    do: {:noreply, push_patch(socket, to: ~p"/goals/#{goal.id}")}

  def handle_event("cancel_goal_edit", _params, socket), do: {:noreply, socket}

  def handle_event("save_goal", %{"goal" => params}, socket) do
    case socket.assigns[:goal] do
      nil ->
        case Goals.create_goal(Map.merge(params, owner_attrs(socket))) do
          {:ok, goal} ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Goal saved."))
             |> push_navigate(to: ~p"/goals/#{goal.id}")}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply, assign(socket, form: to_form(changeset))}
        end

      %Goal{} = goal ->
        # La edición ocurre EN el detalle: al guardar se sale del modo edición
        # con un patch (el detalle no se remonta).
        case Goals.update_goal(goal, params) do
          {:ok, updated} ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Goal saved."))
             |> push_patch(to: ~p"/goals/#{updated.id}")}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply, assign(socket, form: to_form(changeset))}
        end
    end
  end

  def handle_event("delete_goal", _params, %{assigns: %{goal: %Goal{} = goal}} = socket) do
    {:ok, _} = Goals.delete_goal(goal)

    {:noreply,
     socket
     |> put_flash(:info, gettext("Goal deleted."))
     |> push_navigate(to: ~p"/goals")}
  end

  def handle_event("delete_goal", _params, socket), do: {:noreply, socket}

  # Abrir/cerrar el alta de una task: URL state, como el resto (push_patch).
  def handle_event("new_task", _params, %{assigns: %{goal: %Goal{} = goal}} = socket),
    do: {:noreply, push_patch(socket, to: ~p"/goals/#{goal.id}?new_task=true")}

  def handle_event("new_task", _params, socket), do: {:noreply, socket}

  def handle_event("close_task_modal", _params, %{assigns: %{goal: %Goal{} = goal}} = socket),
    do: {:noreply, push_patch(socket, to: ~p"/goals/#{goal.id}")}

  def handle_event("close_task_modal", _params, socket), do: {:noreply, socket}

  # Editar una task del detalle: SIEMPRE modal (paridad con el board). La task
  # se lee con el scope del lector y el modal se cierra al guardar o navegar.
  def handle_event("edit_task", %{"task_id" => id}, socket) do
    scope = socket.assigns[:scope]

    case scope && Tasks.get_task(id, scope: scope) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Task not found"))}

      %Task{} = task ->
        # El form de la edición sale del CHANGESET de la fila: los mismos campos
        # que el alta, con los valores de la task.
        {:noreply,
         assign(socket, editing_task: task, task_edit_form: to_form(Tasks.change_task(task)))}
    end
  end

  def handle_event("edit_task", _params, socket), do: {:noreply, socket}

  def handle_event("close_edit_modal", _params, socket),
    do: {:noreply, assign(socket, editing_task: nil)}

  def handle_event("add_task", %{"task" => %{"title" => title} = params}, socket) do
    case {socket.assigns[:goal], socket.assigns[:scope]} do
      {%Goal{} = goal, scope} when not is_nil(scope) ->
        title = String.trim(title || "")

        if title == "" do
          {:noreply, put_flash(socket, :error, gettext("A task needs a title."))}
        else
          attrs = %{
            "goal_id" => goal.id,
            "title" => title,
            "body" => params["body"],
            "status" => task_status(params["status"]),
            "priority" => blank_to_nil(params["priority"]),
            "due_date" => blank_to_nil(params["due_date"])
          }

          case Tasks.create_task(attrs) do
            {:ok, _task} ->
              {:noreply,
               socket
               |> put_flash(:info, gettext("Task saved."))
               |> push_patch(to: ~p"/goals/#{goal.id}")}

            {:error, %Ecto.Changeset{}} ->
              {:noreply, put_flash(socket, :error, gettext("Could not create the task."))}
          end
        end

      _ ->
        {:noreply, socket}
    end
  end

  # La edición de una task es UNA: el mismo caso de uso que el board
  # (`Tasks.save_edit/3`) — contenido, pasos y estado, cada uno por su puerta.
  def handle_event("update_task", %{"task_id" => id} = params, socket) do
    scope = socket.assigns[:scope]

    case scope && Tasks.get_task(id, scope: scope) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Task not found"))}

      %Task{} = task ->
        case Tasks.save_edit(task, params["task"] || %{},
               checklist: params["checklist"],
               lock_version: params["lock_version"]
             ) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Task saved."))
             |> assign(editing_task: nil)
             |> reload()}

          {:error, :stale} ->
            {:noreply,
             socket
             |> put_flash(:error, gettext("Task was moved elsewhere — reloading"))
             |> reload()}

          {:error, :invalid_status} ->
            {:noreply, put_flash(socket, :error, gettext("Invalid status"))}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Could not save the task."))}
        end
    end
  end

  def handle_event("update_task", _params, socket), do: {:noreply, socket}

  # Borrar la task desde su edición: la misma puerta que el board (el contexto
  # borra la fila y sus aristas, sin dejar nodos muertos en el grafo).
  def handle_event("delete_task", %{"task_id" => id}, socket) do
    scope = socket.assigns[:scope]

    case scope && Tasks.get_task(id, scope: scope) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Task not found"))}

      %Task{} = task ->
        {:ok, _} = Tasks.delete_task(task)

        {:noreply,
         socket
         |> put_flash(:info, gettext("Task deleted."))
         |> assign(editing_task: nil)
         |> reload()}
    end
  end

  def handle_event("delete_task", _params, socket), do: {:noreply, socket}

  def handle_event("add_task", _params, socket), do: {:noreply, socket}

  def handle_event("open_share", _params, %{assigns: %{goal: %Goal{} = goal}} = socket) do
    {:noreply,
     socket
     |> assign(:share_open, true)
     |> assign(:shares, Sharing.list_shares("goal", goal.id))
     |> assign(:share_users, Dran.Accounts.list_users())
     |> assign(:share_groups, Sharing.list_groups())}
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
        %{assigns: %{goal: %Goal{} = goal}} = socket
      )
      when page_id != "" do
    scope = Dran.ContentVisibility.personal_scope(socket.assigns[:user])

    case Dran.Related.link("goal", goal, page_id, socket.assigns[:user],
           scope: scope,
           workspace_id: workspace_id(socket)
         ) do
      {:ok, _relation} ->
        {:noreply,
         socket
         |> assign_related(goal)
         |> put_flash(:info, gettext("Page linked."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not link that page."))}
    end
  end

  def handle_event("link_related", _params, socket), do: {:noreply, socket}

  def handle_event("share_with_user", %{"user_id" => user_id}, %{assigns: %{goal: goal}} = socket)
      when user_id != "" and not is_nil(goal) do
    case Sharing.grant(goal, :goal, {:user, String.to_integer(user_id)}) do
      {:ok, :shared, updated} ->
        {:noreply,
         socket
         |> assign(goal: updated, shares: Sharing.list_shares("goal", goal.id))
         |> put_flash(:info, gettext("Shared."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not share."))}
    end
  end

  def handle_event("share_with_user", _params, socket), do: {:noreply, socket}

  def handle_event(
        "share_with_group",
        %{"group_id" => group_id},
        %{assigns: %{goal: goal}} = socket
      )
      when group_id != "" and not is_nil(goal) do
    case Sharing.grant(goal, :goal, {:group, String.to_integer(group_id)}) do
      {:ok, :shared, updated} ->
        {:noreply,
         socket
         |> assign(goal: updated, shares: Sharing.list_shares("goal", goal.id))
         |> put_flash(:info, gettext("Shared."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not share."))}
    end
  end

  def handle_event("share_with_group", _params, socket), do: {:noreply, socket}

  def handle_event("unshare", %{"id" => share_id}, %{assigns: %{goal: goal}} = socket)
      when not is_nil(goal) do
    :ok = Sharing.unshare(share_id)
    {:noreply, assign(socket, :shares, Sharing.list_shares("goal", goal.id))}
  end

  def handle_event("unshare", _params, socket), do: {:noreply, socket}

  # ──────────────────────────────────────────────────────────────────────────
  # Helpers
  # ──────────────────────────────────────────────────────────────────────────

  # Las páginas relacionadas del goal: las relaciones REALES del grafo primero
  # y, SÓLO si no hay ninguna, el fallback semántico (`Dran.Related`). Lee con
  # la puerta PERSONAL (un owner/admin no ensancha acá) y el alta es el picker.
  defp assign_related(socket, goal) do
    scope = Dran.ContentVisibility.personal_scope(socket.assigns[:user])
    opts = [scope: scope, workspace_id: workspace_id(socket)]

    assign(socket,
      related: Dran.Related.for_entity("goal", goal, opts),
      related_candidates: Dran.Related.linkable_pages("goal", goal, opts)
    )
  end

  defp new_goal_form do
    to_form(Goals.change_goal(%Goal{}, %{"status" => "active", "visibility" => "private"}))
  end

  # El workspace del editor de markdown (wikilinks y uploads), tal como lo pasa
  # pages: el id del contexto, nil si aún no se resolvió.
  defp workspace_id(socket) do
    case socket.assigns[:context] do
      nil -> nil
      context -> context.id
    end
  end

  defp reload(socket) do
    case {socket.assigns[:goal], socket.assigns[:scope]} do
      {%Goal{} = goal, scope} when not is_nil(scope) ->
        socket
        |> assign(
          progress: Goals.progress(goal),
          children: Goals.list_children(goal, scope: scope)
        )
        |> reload_tasks(scope)

      _ ->
        socket
    end
  end

  # Las tasks salen del contexto con `scope:` y se re-emiten como stream
  # (reset: true): una task recién creada no puede quedar desincronizada.
  # Las tasks se AGRUPAN por status (la excepción documentada de los boards
  # agrupados: un stream no se puede rebanar por grupo).
  defp reload_tasks(socket, scope) do
    tasks = Tasks.list_tasks_for_goal(socket.assigns.goal, scope: scope)

    socket
    |> assign(task_count: length(tasks), task_groups: group_tasks(tasks))
  end

  # Sólo los grupos con contenido: un status vacío no se dibuja.
  defp group_tasks(tasks) do
    Task.statuses()
    |> Enum.map(fn status -> {status, Enum.filter(tasks, &(&1.status == status))} end)
    |> Enum.reject(fn {_status, group} -> group == [] end)
  end

  defp new_task_form, do: to_form(%{"status" => "backlog"}, as: :task)

  defp task_status_options,
    do: Enum.map(Task.statuses(), fn st -> {task_status_label(st), st} end)

  defp priority_options, do: Enum.map(Task.priorities(), fn pr -> {pr, pr} end)

  defp task_status(status), do: if(status in Task.statuses(), do: status, else: "backlog")

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value) when is_binary(value), do: String.trim(value)
  defp blank_to_nil(value), do: value

  # El dueño del goal para el bloque Metadata del aside: la tabla guarda el id
  # (`owner_user_id`) y NULL es contenido de sistema (workspace-wide). Se pinta
  # el NOMBRE de la cuenta, nunca el id crudo (C11). El goal no declara actor ni
  # versionado, así que esto es lo que hay — igual que el `updated_at` de al lado.
  defp owner_label(nil), do: gettext("Instance")

  defp owner_label(user_id) when is_integer(user_id) do
    case Accounts.get_user(user_id) do
      nil -> gettext("Unknown")
      user -> user.name || user.email
    end
  end

  defp owner_label(_other), do: gettext("Unknown")

  defp task_status_label("backlog"), do: gettext("Backlog")
  defp task_status_label("todo"), do: gettext("To Do")
  defp task_status_label("in_progress"), do: gettext("In Progress")
  defp task_status_label("done"), do: gettext("Done")
  defp task_status_label("cancelled"), do: gettext("Cancelled")
  defp task_status_label(other), do: other

  # El destino lo administra quien puede escribir: el DUEÑO (constraint 8). El
  # diálogo agrega y quita grants; compartir fija `shared` en la misma operación.
  defp can_manage_scope?(%{owner_user_id: owner_id}, %{id: id}), do: owner_id == id
  defp can_manage_scope?(_resource, _user), do: false

  defp reader_scope(socket) do
    case socket.assigns[:user] do
      nil -> nil
      user -> Dran.ContentVisibility.resolve(socket.assigns[:context], user, :goal)
    end
  end

  # El dueño sale de la SESIÓN, nunca del formulario (Constraint 3).
  defp owner_attrs(socket) do
    case Dran.Auth.resolve_owner_user_id(socket.assigns[:user]) do
      nil -> %{}
      user_id -> %{"owner_user_id" => user_id}
    end
  end

  defp fetch_goal(id_or_slug, scope) do
    case cast_uuid(id_or_slug) do
      {:ok, uuid} -> Goals.get_goal(uuid, scope: scope)
      :error -> Goals.get_goal_by_slug(id_or_slug, scope: scope)
    end
  end

  defp cast_uuid(value) when is_binary(value) do
    if byte_size(value) == 36, do: Ecto.UUID.cast(value), else: :error
  end

  defp cast_uuid(_), do: :error

  defp empty_progress,
    do: %{done: 0, total: 0, derived_percent: 0, manual: nil, percent: 0}

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

  defp goals_path(query) do
    pairs =
      for field <- @query_fields,
          value = query[field],
          value not in [nil, ""],
          not (field == "order" and value == @default_order),
          do: {field, value}

    case URI.encode_query(pairs) do
      "" -> "/goals"
      qs -> "/goals?" <> qs
    end
  end

  defp dot_class("backlog"), do: "bg-base-300"
  defp dot_class("todo"), do: "bg-sky-500"
  defp dot_class("in_progress"), do: "bg-purple-500"
  defp dot_class("done"), do: "bg-green-500"
  defp dot_class("cancelled"), do: "bg-red-400"
  defp dot_class(_), do: "bg-base-300"
end
