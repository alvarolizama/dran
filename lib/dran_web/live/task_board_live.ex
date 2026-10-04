defmodule DranWeb.TaskBoardLive do
  @moduledoc """
  El board del contenedor de trabajo — dos caras del mismo LiveView.

    * el **board global** (`/tasks`, `:index`) — las tasks de todos los goals
      que el lector puede leer;
    * el **board de un goal** (`/tasks/:id`, `:show`) — las tasks de ESE goal
      (`:id` es el goal; uuid primero y slug de respaldo, Constraint 14).

  Las columnas son los status de `Dran.Tasks.Task.statuses/0` y el orden dentro
  de la columna sale de `position`. Mover una task pasa SIEMPRE por
  `Dran.Tasks.move_task/2` — el único camino que respeta `lock_version` y
  renumera: la UI nunca toca `position` ni `lock_version`.

  Desde el contrato de paridad UI/UX el board tiene lo que pages ya tenía:

    * **filtros** de goal + estado + responsable, con el estado en el socket Y en
      la query string (`?goal_id=&status=&assignee_id=`, así el filtro se comparte
      y sobrevive al reload) — servidos por `Dran.Tasks.list_tasks/1`, que ya
      acepta `goal_id`, `status` y `assignee_id`;
    * el **alta de una task en el MISMO `<.resource_modal>` de pages**, abierto
      por `?new=true`, con **selector de goal**: el default es el goal elegido →
      el goal del filtro → el del tablero → la bandeja del dueño
      (`Dran.Goals.ensure_inbox/1`), la misma regla que la API;
    * la **edición de una task en ese mismo modal** (no dentro de la tarjeta):
      el `Edit` de la tarjeta abre el modal con el checklist en su puerta.

  Mover una task, en cambio, no se toca desde la tarjeta: se **arrastra** a otra
  columna (`drag & drop`, hook colocado `.TaskDrag` → el evento `move`). Y el
  filtro por **responsable** es de ADMIN: es el control que enumera las personas
  de la instancia, así que un no-owner ni lo ve ni lo aplica por query string.

  Toda lectura sale de los contextos con `scope:` resuelto por la política única
  (`Dran.ContentVisibility`). Por eso ni el board ni el selector de goal ofrecen
  un goal que el lector no puede leer, el board global no muestra tasks de goals
  ajenos privados y el board de un goal ajeno privado navega fuera.
  """

  use DranWeb, :live_view

  alias Dran.{Goals, Tasks}
  alias Dran.Goals.Goal
  alias Dran.Tasks.Task
  alias DranWeb.Plugs.Auth

  @column_meta [
    {"backlog", "hero-inbox", "bg-base-300"},
    {"todo", "hero-list-bullet", "bg-sky-500/20 text-sky-700"},
    {"in_progress", "hero-bolt", "bg-purple-500/20 text-purple-700"},
    {"done", "hero-check-circle", "bg-green-500/20 text-green-700"},
    {"cancelled", "hero-x-circle", "bg-red-500/20 text-red-700"}
  ]

  # ──────────────────────────────────────────────────────────────────────────
  # Render
  # ──────────────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(modal_open: Map.get(assigns, :modal_open, false))
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
      <div id="task-board" class="p-6 w-full">
        <div class="flex items-center justify-between gap-4 mb-6 flex-wrap">
          <div class="min-w-0">
            <h1 class="text-2xl font-bold flex items-center gap-2">
              <.icon name="hero-view-columns" class="size-6 text-primary" />
              {if @goal, do: @goal.title, else: gettext("Tasks")}
            </h1>
            <p :if={@goal && @goal.summary} class="text-caption mt-1">{@goal.summary}</p>
          </div>
          <div class="flex items-center gap-3 flex-wrap">
            <button type="button" id="task-new" phx-click="new_task" class="btn btn-primary btn-sm">
              <.icon name="hero-plus" class="size-4" /> {gettext("New task")}
            </button>

            <.link
              :if={@live_action == :show}
              navigate={~p"/tasks"}
              id="board-all-tasks"
              class="btn btn-ghost btn-sm"
            >
              <.icon name="hero-arrow-left" class="size-4" /> {gettext("All tasks")}
            </.link>
          </div>
        </div>

        <%!-- Filtros: goal + estado + responsable. El estado vive en la URL. --%>
        <form id="board-filters" phx-change="filter" class="flex items-center gap-2 flex-wrap mb-4">
          <select
            :if={@live_action == :index && @goals != []}
            name="goal_id"
            id="board-goal-filter-select"
            class="select select-sm select-bordered"
            aria-label={gettext("Filter by goal")}
          >
            <option value="" selected={is_nil(@filters.goal_id)}>{gettext("All goals")}</option>
            <option :for={goal <- @goals} value={goal.id} selected={@filters.goal_id == goal.id}>
              {goal.title}
            </option>
          </select>

          <select
            name="status"
            id="board-status-filter"
            class="select select-sm select-bordered"
            aria-label={gettext("Filter by status")}
          >
            <option value="" selected={is_nil(@filters.status)}>{gettext("All statuses")}</option>
            <option :for={s <- @statuses} value={s} selected={@filters.status == s}>
              {column_label(s)}
            </option>
          </select>

          <%!-- El filtro por responsable es de ADMIN: es el control que enumera
          las personas de la instancia (`Accounts.list_users/0`). Un no-owner no
          lo ve y su `?assignee_id=` se ignora (`filters_from/2`). --%>
          <select
            :if={@is_owner}
            name="assignee_id"
            id="board-assignee-filter"
            class="select select-sm select-bordered"
            aria-label={gettext("Filter by assignee")}
          >
            <option value="" selected={is_nil(@filters.assignee_id)}>{gettext("Everyone")}</option>
            <option
              :for={user <- @assignees}
              value={user.id}
              selected={@filters.assignee_id == user.id}
            >
              {user.name || user.email}
            </option>
          </select>
        </form>

        <%!-- El tablero es la superficie de drag & drop: arrastrar una
        tarjeta sobre otra columna dispara `move` — la única puerta del dominio
        (`Tasks.move_task/2`), así que la UI sigue sin tocar position ni
        lock_version. --%>
        <div
          id="board-columns"
          phx-hook=".TaskDrag"
          class="flex gap-4 pb-4 items-start overflow-x-auto"
        >
          <div
            :for={{status, icon, badge_class} <- @columns}
            id={"column-#{status}"}
            data-column={status}
            class="flex-1 min-w-[240px] flex flex-col rounded-2xl bg-base-200/40 border border-base-300 overflow-hidden"
          >
            <div class="flex items-center justify-between px-3 py-2.5 border-b border-base-300">
              <div class="flex items-center gap-2">
                <.icon name={icon} class="size-4 text-base-content/60" />
                <span class="text-sm font-semibold">{column_label(status)}</span>
              </div>
              <span class={"badge badge-sm #{badge_class}"}>{Map.get(@counts, status, 0)}</span>
            </div>

            <div class="p-2 space-y-2 min-h-[80px] flex-1">
              <div
                :for={task <- Map.get(@board, status, [])}
                id={"task-card-#{task.id}"}
                data-task-id={task.id}
                draggable="true"
                class="p-3 rounded-xl bg-base-100 border border-base-300 shadow-sm space-y-2 cursor-grab active:cursor-grabbing"
              >
                <div class="flex items-start gap-2">
                  <div class="flex-1 min-w-0 font-medium text-sm break-words">{task.title}</div>
                  <%!-- El asa es la pista; el drag lo lleva la tarjeta entera. --%>
                  <.icon name="hero-bars-2" class="size-4 shrink-0 text-base-content/25" />
                </div>

                <div
                  :if={@live_action == :index && Map.get(@goal_titles, task.goal_id)}
                  class="flex items-center gap-1 text-xs text-base-content/50 min-w-0"
                >
                  <.icon name="hero-flag" class="size-3.5 text-green-600 shrink-0" />
                  <span class="truncate">{Map.get(@goal_titles, task.goal_id)}</span>
                </div>

                <div :if={task.checklist != []} class="space-y-0.5">
                  <div
                    :for={{item, index} <- Enum.with_index(task.checklist)}
                    class="flex items-center gap-1.5 text-xs"
                  >
                    <button
                      id={"task-check-#{task.id}-#{index}"}
                      phx-click="toggle_check"
                      phx-value-task_id={task.id}
                      phx-value-index={index}
                      class="shrink-0 text-base-content/40 hover:text-primary"
                      aria-label={gettext("Toggle step")}
                    >
                      <.icon
                        name={if item["done"], do: "hero-check-circle", else: "hero-circle-stack"}
                        class={["size-4", item["done"] && "text-green-600"]}
                      />
                    </button>
                    <span class={[
                      "min-w-0 truncate",
                      item["done"] && "line-through text-base-content/40"
                    ]}>
                      {item["text"]}
                    </span>
                  </div>
                </div>

                <%!-- Mover no se toca desde la tarjeta: se ARRASTRA a otra
                columna (el hook dispara `move`). Editar abre SIEMPRE el modal
                del molde de pages — la tarjeta no expande formularios dentro
                del tablero, y así el drag no pelea con inputs. --%>
                <button
                  type="button"
                  id={"task-edit-#{task.id}"}
                  phx-click="edit_task"
                  phx-value-task_id={task.id}
                  class="text-xs text-base-content/50 hover:text-base-content/80"
                >
                  {gettext("Edit")}
                </button>
              </div>

              <p
                :if={Map.get(@board, status, []) == []}
                class="text-xs text-base-content/30 text-center py-4"
              >
                {gettext("Empty")}
              </p>
            </div>
          </div>
        </div>
      </div>

      <%!-- Drag & drop del board. Hook COLOCADO (el compiler lo mete en el
      bundle: nada de `<script>` sueltos) y SÓLO eventos del DOM → `pushEvent`:
      la tarjeta (`data-task-id`) es el payload y la columna (`data-column`) el
      destino. El servidor no cambia — el move sigue entrando por `move`. --%>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".TaskDrag">
        export default {
          mounted() {
            this.card = null
            this.column = null

            this.el.addEventListener("dragstart", (event) => {
              const card = event.target.closest?.("[data-task-id]")
              if (!card) return
              this.card = card
              event.dataTransfer.setData("text/plain", card.dataset.taskId)
              event.dataTransfer.effectAllowed = "move"
              card.classList.add("opacity-50")
            })

            this.el.addEventListener("dragend", () => {
              if (this.card) this.card.classList.remove("opacity-50")
              this.card = null
              this.highlight(null)
            })

            this.el.addEventListener("dragover", (event) => {
              const column = event.target.closest?.("[data-column]")
              if (!column || !this.card) return
              event.preventDefault()
              event.dataTransfer.dropEffect = "move"
              this.highlight(column)
            })

            this.el.addEventListener("dragleave", (event) => {
              if (this.column && !this.column.contains(event.relatedTarget)) this.highlight(null)
            })

            this.el.addEventListener("drop", (event) => {
              const column = event.target.closest?.("[data-column]")
              const card = this.card
              this.highlight(null)
              if (!column || !card) return
              event.preventDefault()
              // Misma columna: no hay nada que mover.
              if (card.closest("[data-column]") === column) return
              this.pushEvent("move", {task_id: card.dataset.taskId, status: column.dataset.column})
            })
          },

          highlight(column) {
            if (this.column === column) return
            if (this.column) this.column.classList.remove("ring-2", "ring-primary/60")
            this.column = column
            if (column) column.classList.add("ring-2", "ring-primary/60")
          }
        }
      </script>

      <%!-- ── Alta y edición de una TASK: el MISMO modal que el detalle del
      goal (`DranWeb.TaskComponents`). El board aporta lo suyo: el goal es
      elegible al crear (acá nace la task) y el borrado vive en la edición. ── --%>
      <.task_modal
        :if={@modal_open}
        id="task-resource-modal"
        title={gettext("New task")}
        on_close="close_task_modal"
        form_id="task-form"
        prefix="task"
        submit="create_task"
        submit_label={gettext("Create")}
        form={@task_form}
        workspace_id={@workspace_id}
        goal_options={Enum.map(@goals, &{&1.title, &1.id})}
        statuses={Enum.map(@statuses, &{column_label(&1), &1})}
        priorities={Enum.map(Task.priorities(), &{&1, &1})}
      />

      <%!-- Editar una task: el modal del molde, con los pasos (su puerta: RMW +
      lock_version) y el borrado. La tarjeta nunca expande un form adentro. --%>
      <.task_modal
        :if={@editing_task}
        id="task-edit-modal"
        title={gettext("Edit task")}
        on_close="close_edit_modal"
        form_id={"task-edit-form-#{@editing_task.id}"}
        prefix={"task-edit-#{@editing_task.id}"}
        submit="update_task"
        submit_label={gettext("Save")}
        form={@task_edit_form}
        workspace_id={@workspace_id}
        task={@editing_task}
        checklist={@editing_task.checklist}
        on_delete="delete_task"
        statuses={Enum.map(@statuses, &{column_label(&1), &1})}
        priorities={Enum.map(Task.priorities(), &{&1, &1})}
      />
    </Layouts.app>
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
       workspace_id: context && context.id,
       columns: @column_meta,
       statuses: Task.statuses(),
       active_nav: "board",
       goals: [],
       goal_titles: %{},
       goal: nil,
       filters: empty_filters(),
       assignees: assignees(socket),
       scope: nil,
       board: empty_board(),
       counts: empty_counts(),
       modal_open: false,
       editing_task: nil,
       task_form: task_form(%{}),
       task_edit_form: task_form(%{})
     )}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  # El board global: los filtros salen de la query string (compartible).
  defp apply_action(socket, :index, params) do
    case reader_scope(socket) do
      nil ->
        push_navigate(socket, to: ~p"/")

      scope ->
        # El form del alta se arma DESPUÉS de tener los filtros vigentes: si se
        # armara con el socket viejo, el default de goal/estado sería el de la
        # navegación anterior.
        socket =
          socket
          |> assign(
            filters: filters_from(params, socket.assigns[:is_owner]),
            goal: nil,
            modal_open: params["new"] == "true",
            editing_task: nil
          )
          |> load_board(scope)

        assign(socket, task_form: task_form(default_task_attrs(socket)))
    end
  end

  # El board de un goal: el goal del tablero manda; estado y responsable filtran.
  defp apply_action(socket, :show, %{"id" => id_or_slug} = params) do
    case reader_scope(socket) do
      nil ->
        push_navigate(socket, to: ~p"/")

      scope ->
        case fetch_goal(id_or_slug, scope) do
          # Un goal ajeno privado es inexistente: se navega fuera, no se abre.
          nil ->
            push_navigate(socket, to: ~p"/tasks")

          goal ->
            socket =
              socket
              |> assign(
                goal: goal,
                filters:
                  Map.put(filters_from(params, socket.assigns[:is_owner]), :goal_id, goal.id),
                modal_open: params["new"] == "true",
                editing_task: nil
              )
              |> load_board(scope)

            assign(socket, task_form: task_form(default_task_attrs(socket)))
        end
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Events
  # ──────────────────────────────────────────────────────────────────────────

  # Los filtros viven en la URL: cambiar uno es un patch, no un assign suelto.
  @impl true
  def handle_event("filter", params, socket) do
    query = %{
      "goal_id" => params["goal_id"],
      "status" => params["status"],
      "assignee_id" => params["assignee_id"]
    }

    {:noreply, push_patch(socket, to: board_path(socket, query))}
  end

  # Abrir/cerrar el alta es URL state (el mismo molde de pages): patch, no ruta.
  def handle_event("new_task", _params, socket),
    do:
      {:noreply,
       push_patch(socket, to: board_path(socket, current_query(socket) |> Map.put("new", "true")))}

  def handle_event("close_task_modal", _params, socket),
    do: {:noreply, push_patch(socket, to: board_path(socket, current_query(socket)))}

  def handle_event("move", %{"task_id" => id, "status" => status}, socket) do
    scope = socket.assigns[:scope]

    cond do
      is_nil(scope) ->
        {:noreply, socket}

      status not in Task.statuses() ->
        {:noreply, put_flash(socket, :error, gettext("Invalid status"))}

      true ->
        case Tasks.get_task(id, scope: scope) do
          nil ->
            {:noreply, put_flash(socket, :error, gettext("Task not found"))}

          %Task{} = task ->
            case Tasks.move_task(task, %{"status" => status}) do
              {:ok, _updated} ->
                {:noreply, reload(socket)}

              {:error, :stale} ->
                {:noreply,
                 socket
                 |> put_flash(:error, gettext("Task was moved elsewhere — reloading"))
                 |> reload()}

              {:error, %Ecto.Changeset{}} ->
                {:noreply, put_flash(socket, :error, gettext("Could not move task"))}
            end
        end
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Crear, editar, borrar y tachar — la superficie de administración
  # ──────────────────────────────────────────────────────────────────────────

  # Editar SIEMPRE abre el modal: la tarjeta no expande un form. La task se lee
  # con el scope del lector (una ajena no se edita) y el modal se cierra solo al
  # guardar, borrar o navegar.
  def handle_event("edit_task", %{"task_id" => id}, socket) do
    scope = socket.assigns[:scope]

    case scope && Tasks.get_task(id, scope: scope) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Task not found"))}

      %Task{} = task ->
        # El form de la edición sale del CHANGESET de la fila: los mismos campos
        # que el alta (y los mismos que el detalle del goal), con sus valores.
        {:noreply,
         assign(socket, editing_task: task, task_edit_form: to_form(Tasks.change_task(task)))}
    end
  end

  def handle_event("edit_task", _params, socket), do: {:noreply, socket}

  def handle_event("close_edit_modal", _params, socket),
    do: {:noreply, assign(socket, editing_task: nil)}

  # El alta: el goal sale del selector, con el default en orden (elegido → el
  # filtro → el del tablero → la bandeja del dueño) y el estado del filtro
  # activo (o el default del schema). Un goal que el lector no puede leer es
  # `:error`, nunca un create silencioso en otro lado.
  def handle_event("create_task", %{"task" => params}, socket) do
    scope = socket.assigns[:scope]
    title = String.trim(params["title"] || "")

    cond do
      is_nil(scope) ->
        {:noreply, socket}

      title == "" ->
        {:noreply,
         put_flash(socket, :error, gettext("A task needs a title."))
         |> assign(task_form: task_form(params))}

      true ->
        case resolve_task_goal(socket, params["goal_id"]) do
          {:ok, goal} ->
            attrs = %{
              "goal_id" => goal.id,
              "title" => title,
              "body" => params["body"],
              "status" => task_status(socket, params["status"]),
              "priority" => blank_to_nil(params["priority"]),
              "due_date" => blank_to_nil(params["due_date"])
            }

            case Tasks.create_task(attrs) do
              {:ok, _task} ->
                {:noreply,
                 socket
                 |> put_flash(:info, gettext("Task saved."))
                 |> push_patch(to: board_path(socket, current_query(socket)))}

              {:error, %Ecto.Changeset{}} ->
                {:noreply,
                 socket
                 |> put_flash(:error, gettext("Could not create the task."))
                 |> assign(task_form: task_form(params))}
            end

          {:error, message} ->
            {:noreply, put_flash(socket, :error, message) |> assign(task_form: task_form(params))}
        end
    end
  end

  def handle_event("create_task", _params, socket), do: {:noreply, socket}

  def handle_event("update_task", %{"task_id" => id} = params, socket) do
    scope = socket.assigns[:scope]

    case scope && Tasks.get_task(id, scope: scope) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Task not found"))}

      %Task{} = task ->
        # La edición de una task es UNA: el mismo caso de uso que el detalle del
        # goal (`Tasks.save_edit/3`) — contenido, pasos y estado, cada uno por su
        # puerta, en el orden que respeta el `lock_version`.
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

  def handle_event("toggle_check", %{"task_id" => id, "index" => index}, socket) do
    scope = socket.assigns[:scope]

    case scope && Tasks.get_task(id, scope: scope) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Task not found"))}

      %Task{} = task ->
        case Tasks.toggle_checklist(task, String.to_integer(index),
               lock_version: task.lock_version
             ) do
          {:ok, _} ->
            {:noreply, reload(socket)}

          {:error, :stale} ->
            {:noreply,
             socket
             |> put_flash(:error, gettext("Task was moved elsewhere — reloading"))
             |> reload()}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Could not update the step."))}
        end
    end
  end

  def handle_event("toggle_check", _params, socket), do: {:noreply, socket}

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

  # ──────────────────────────────────────────────────────────────────────────
  # Helpers
  # ──────────────────────────────────────────────────────────────────────────

  @doc false
  def empty_filters, do: %{goal_id: nil, status: nil, assignee_id: nil}

  # El directorio de personas sólo lo carga un ADMIN: el filtro por responsable
  # es suyo, así que a un no-owner ni le llega la lista.
  defp assignees(socket) do
    if socket.assigns[:is_owner], do: Dran.Accounts.list_users(), else: []
  end

  # Arma el board desde los contextos (scope-leídos) con los filtros vigentes:
  # `goal_id`, `status` y `assignee_id` ya los acepta `Tasks.list_tasks/1`.
  defp load_board(socket, scope) do
    filters = socket.assigns.filters
    goal = socket.assigns[:goal]
    goal_id = (goal && goal.id) || filters.goal_id

    goals = Goals.list_goals(scope: scope)

    tasks =
      Tasks.list_tasks(
        scope: scope,
        goal_id: goal_id,
        status: filters.status,
        assignee_id: filters.assignee_id
      )

    board = group_board(tasks)

    assign(socket,
      scope: scope,
      goals: goals,
      goal_titles: Map.new(goals, &{&1.id, &1.title}),
      filter_goal_id: goal_id,
      board: board,
      counts: Map.new(board, fn {status, ts} -> {status, length(ts)} end),
      page_title: (goal && goal.title) || gettext("Tasks")
    )
  end

  defp reload(socket) do
    load_board(socket, socket.assigns.scope)
  end

  # El goal donde nace una task nueva: el elegido en el modal → el del filtro →
  # el del tablero → la bandeja del dueño (la regla de `POST /api/tasks`).
  # Un goal elegido que el lector no puede leer es `:error`, no un fallback.
  defp resolve_task_goal(socket, chosen) do
    scope = socket.assigns[:scope]

    cond do
      is_binary(chosen) and chosen != "" ->
        case Goals.get_goal(chosen, scope: scope) do
          nil -> {:error, gettext("That goal is not available.")}
          goal -> {:ok, goal}
        end

      is_binary(socket.assigns.filters.goal_id) ->
        case Goals.get_goal(socket.assigns.filters.goal_id, scope: scope) do
          nil -> inbox_goal(socket)
          goal -> {:ok, goal}
        end

      match?(%Goal{}, socket.assigns[:goal]) ->
        {:ok, socket.assigns.goal}

      true ->
        inbox_goal(socket)
    end
  end

  defp inbox_goal(socket) do
    case Goals.ensure_inbox(socket.assigns[:user]) do
      {:ok, goal} -> {:ok, goal}
      {:error, :no_owner} -> {:error, gettext("No owner for the inbox goal.")}
      {:error, _} -> {:error, gettext("Could not open the inbox goal.")}
    end
  end

  # El estado de la task nueva: el del modal → el del filtro activo → el default.
  defp task_status(socket, chosen) do
    cond do
      chosen in Task.statuses() -> chosen
      socket.assigns.filters.status in Task.statuses() -> socket.assigns.filters.status
      true -> "backlog"
    end
  end

  # Los atributos con los que abre el modal: el goal y el estado por defecto ya
  # elegidos, para que el submit sea un click.
  defp default_task_attrs(socket) do
    goal_id =
      case socket.assigns[:goal] do
        %Goal{id: id} -> id
        _ -> socket.assigns.filters.goal_id
      end

    %{"goal_id" => goal_id, "status" => task_status(socket, nil)}
  end

  defp task_form(params), do: to_form(params, as: :task)

  # Filtros desde la query string, validados contra el vocabulario real. El
  # responsable sólo lo filtra un ADMIN: el control que enumera las personas de
  # la instancia es suyo, así que el `?assignee_id=` de un no-owner se ignora en
  # vez de dejar un filtro invisible aplicado.
  defp filters_from(params, is_owner) do
    %{
      goal_id: blank_to_nil(params["goal_id"]),
      status: (params["status"] in Task.statuses() && params["status"]) || nil,
      assignee_id: (is_owner && parse_int(params["assignee_id"])) || nil
    }
  end

  # El query string vigente (sin lo vacío): es lo que hace compartible el filtro.
  defp current_query(socket) do
    %{
      "goal_id" => socket.assigns.filters.goal_id,
      "status" => socket.assigns.filters.status,
      "assignee_id" => socket.assigns.filters.assignee_id
    }
  end

  # La URL del board con su query: el board de un goal NO repite el goal en la
  # query (el goal es la ruta), el global sí. El orden de los campos es fijo —
  # así la URL es estable y un test puede afirmarla entera.
  @query_fields ~w(goal_id status assignee_id new)

  defp board_path(socket, query) do
    query =
      if match?(%Goal{}, socket.assigns[:goal]), do: Map.drop(query, ["goal_id"]), else: query

    pairs =
      for field <- @query_fields,
          value = query[field],
          value not in [nil, ""],
          do: {field, value}

    case URI.encode_query(pairs) do
      "" -> board_base(socket)
      qs -> board_base(socket) <> "?" <> qs
    end
  end

  defp board_base(socket) do
    case socket.assigns[:goal] do
      %Goal{id: id} -> "/tasks/#{id}"
      _ -> "/tasks"
    end
  end

  # El checklist del formulario y el estado van por dentro de
  # `Tasks.save_edit/3`: acá no queda nada propio que decidir.

  # Todas las columnas, aun vacías.
  defp group_board(tasks) do
    Map.new(Task.statuses(), fn status ->
      {status, Enum.filter(tasks, &(&1.status == status))}
    end)
  end

  defp empty_board, do: group_board([])
  defp empty_counts, do: Map.new(Task.statuses(), &{&1, 0})

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value) when is_binary(value), do: String.trim(value)
  defp blank_to_nil(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_int(value) when is_integer(value), do: value
  defp parse_int(_), do: nil

  # El scope de lectura de esta superficie, resuelto por la política única. Una
  # sesión sin fila en `users` devuelve `nil` — el caller navega fuera en vez de
  # consultar, porque entregarle ese caso a la política heredaría el `:all` que
  # documenta para identidad nil (misma postura que `PageDetail.reader_scope/1`).
  defp reader_scope(socket) do
    case socket.assigns[:user] do
      nil -> nil
      user -> Dran.ContentVisibility.resolve(socket.assigns[:context], user, :goal)
    end
  end

  # El `:id` de la ruta es uuid primero (36 bytes canónicos) y slug de respaldo:
  # `Ecto.UUID.cast/1` acepta un binario crudo de 16 bytes, así que un slug de
  # 16 chars se leería como uuid y el lookup fallaría. El guard de longitud va
  # ANTES del cast, igual que en las superficies de páginas.
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

  defp column_label("backlog"), do: gettext("Backlog")
  defp column_label("todo"), do: gettext("To Do")
  defp column_label("in_progress"), do: gettext("In Progress")
  defp column_label("done"), do: gettext("Done")
  defp column_label("cancelled"), do: gettext("Cancelled")
  defp column_label(other), do: other
end
