defmodule DranWeb.TaskBoardLive do
  @moduledoc """
  El board del contenedor de trabajo — dos caras del mismo LiveView.

    * el **board global** (`/tasks`, `:index`) — las tasks de todos los goals
      que el lector puede leer, filtrable por goal;
    * el **board de un goal** (`/tasks/:id`, `:show`) — las tasks de ESE goal
      (`:id` es el goal; uuid primero y slug de respaldo, Constraint 14).

  Las columnas son los status de `Dran.Tasks.Task.statuses/0` y el orden dentro
  de la columna sale de `position`. Mover una task pasa SIEMPRE por
  `Dran.Tasks.move_task/2` — el único camino que respeta `lock_version` y
  renumera: la UI nunca toca `position` ni `lock_version`.

  Toda lectura sale de los contextos con `scope:` resuelto por la política única
  (`Dran.ContentVisibility`). Por eso el board global no muestra tasks de goals
  ajenos privados y el board de un goal ajeno privado navega fuera.
  """

  use DranWeb, :live_view

  alias Dran.{Goals, Tasks}
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
            <%!-- Board global: el filtro por goal ofrece SOLO los goals legibles. --%>
            <form
              :if={@live_action == :index && @goals != []}
              id="board-goal-filter"
              phx-change="filter_goal"
            >
              <select
                name="goal_id"
                id="board-goal-filter-select"
                class="select select-sm select-bordered"
                aria-label={gettext("Filter by goal")}
              >
                <option value="" selected={is_nil(@filter_goal_id)}>{gettext("All goals")}</option>
                <option :for={goal <- @goals} value={goal.id} selected={@filter_goal_id == goal.id}>
                  {goal.title}
                </option>
              </select>
            </form>

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

        <div class="flex gap-4 pb-4 items-start overflow-x-auto">
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
                class="p-3 rounded-xl bg-base-100 border border-base-300 shadow-sm space-y-2"
              >
                <div class="font-medium text-sm break-words">{task.title}</div>

                <div
                  :if={@live_action == :index && Map.get(@goal_titles, task.goal_id)}
                  class="flex items-center gap-1 text-xs text-base-content/50 min-w-0"
                >
                  <.icon name="hero-flag" class="size-3.5 text-green-600 shrink-0" />
                  <span class="truncate">{Map.get(@goal_titles, task.goal_id)}</span>
                </div>

                <%!-- El move pasa por move_task/2: NO se toca position ni lock_version. --%>
                <form id={"task-move-#{task.id}"} phx-change="move">
                  <input type="hidden" name="task_id" value={task.id} />
                  <select
                    name="status"
                    id={"task-move-select-#{task.id}"}
                    class="select select-xs select-bordered w-full"
                    aria-label={gettext("Move task")}
                  >
                    <option :for={s <- @statuses} value={s} selected={s == task.status}>
                      {column_label(s)}
                    </option>
                  </select>
                </form>
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
       columns: @column_meta,
       statuses: Task.statuses(),
       active_nav: "board",
       goals: [],
       goal_titles: %{},
       goal: nil,
       filter_goal_id: nil,
       scope: nil,
       board: empty_board(),
       counts: empty_counts()
     )}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    case reader_scope(socket) do
      nil -> push_navigate(socket, to: ~p"/")
      scope -> load_board(socket, scope, nil, nil)
    end
  end

  defp apply_action(socket, :show, %{"id" => id_or_slug}) do
    case reader_scope(socket) do
      nil ->
        push_navigate(socket, to: ~p"/")

      scope ->
        case fetch_goal(id_or_slug, scope) do
          # Un goal ajeno privado es inexistente: se navega fuera, no se abre.
          nil -> push_navigate(socket, to: ~p"/tasks")
          goal -> load_board(socket, scope, goal.id, goal)
        end
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Events
  # ──────────────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("filter_goal", %{"goal_id" => goal_id}, socket) do
    filter =
      case goal_id do
        "" -> nil
        id when is_binary(id) -> id
        _ -> nil
      end

    case socket.assigns[:scope] do
      nil -> {:noreply, socket}
      scope -> {:noreply, load_board(socket, scope, filter, nil)}
    end
  end

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
  # Helpers
  # ──────────────────────────────────────────────────────────────────────────

  # Arma el board desde los contextos (scope-leídos) y lo asigna. `goal_filter`
  # nil = board global; un id = board de ese goal.
  defp load_board(socket, scope, goal_filter, goal) do
    goals = Goals.list_goals(scope: scope)
    tasks = Tasks.list_tasks(scope: scope, goal_id: goal_filter)
    board = group_board(tasks)

    assign(socket,
      scope: scope,
      goals: goals,
      goal_titles: Map.new(goals, &{&1.id, &1.title}),
      goal: goal,
      filter_goal_id: goal_filter,
      board: board,
      counts: Map.new(board, fn {status, ts} -> {status, length(ts)} end),
      page_title: (goal && goal.title) || gettext("Tasks")
    )
  end

  defp reload(socket) do
    load_board(socket, socket.assigns.scope, socket.assigns.filter_goal_id, socket.assigns.goal)
  end

  # Todas las columnas, aun vacías.
  defp group_board(tasks) do
    Map.new(Task.statuses(), fn status ->
      {status, Enum.filter(tasks, &(&1.status == status))}
    end)
  end

  defp empty_board, do: group_board([])
  defp empty_counts, do: Map.new(Task.statuses(), &{&1, 0})

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
