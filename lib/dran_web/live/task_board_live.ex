defmodule DranWeb.TaskBoardLive do
  @moduledoc """
  Interactive task board (kanban) with native HTML5 drag & drop.

  Columns come from `Dran.Task.statuses/0`. Moves go through
  `Dran.Tasks.move_task/3` (optimistic locking + position renumbering).
  A stale lock shows a flash and reloads the board from the server — the
  losing client sees the winner's state instead of silently overwriting it.
  """

  use DranWeb, :live_view

  alias Dran.{Tasks, Task}

  @column_meta [
    {"backlog", "hero-archive-box", "bg-base-300"},
    {"this_week", "hero-calendar", "bg-blue-500/20 text-blue-700"},
    {"today", "hero-sun", "bg-amber-500/20 text-amber-700"},
    {"in_progress", "hero-bolt", "bg-purple-500/20 text-purple-700"},
    {"done", "hero-check-circle", "bg-green-500/20 text-green-700"},
    {"cancelled", "hero-x-circle", "bg-red-500/20 text-red-700"}
  ]

  def mount(%{"workspace_slug" => workspace_slug}, _session, socket) do
    workspace = Dran.Knowledge.get_workspace_by_slug(workspace_slug)

    if workspace do
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Dran.PubSub, "brain:#{workspace.id}")
        Phoenix.PubSub.subscribe(Dran.PubSub, "workspace:#{workspace.id}")
      end

      {:ok,
       socket
       |> assign(workspace: workspace, columns: @column_meta)
       |> load_board()}
    else
      {:ok, push_navigate(socket, to: ~p"/")}
    end
  end

  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  def handle_event("move", %{"id" => id, "to_status" => to_status} = params, socket) do
    task = Tasks.get_task(id)

    case task do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Task not found"))}

      %Task{} = task ->
        opts =
          case params["before_id"] do
            nil -> []
            before_id when is_binary(before_id) -> [before_id: before_id]
            _ -> []
          end

        case Tasks.move_task(task, to_status, opts) do
          {:ok, _updated} ->
            {:noreply, load_board(socket)}

          {:error, :stale} ->
            # Another client moved it first — reload to their state.
            {:noreply,
             socket
             |> put_flash(:error, gettext("Task was moved elsewhere — reloading"))
             |> load_board()}

          {:error, %Ecto.Changeset{} = changeset} ->
            reason =
              changeset.errors
              |> Enum.map_join(", ", fn {_field, {msg, _opts}} -> msg end)

            {:noreply,
             put_flash(
               socket,
               :error,
               gettext("Could not move task: %{reason}", reason: reason)
             )}
        end
    end
  end

  def handle_event("quick_add", %{"task" => %{"title" => title, "status" => status}}, socket) do
    attrs = %{
      "workspace_id" => socket.assigns.workspace.id,
      "title" => String.trim(title),
      "status" => status
    }

    if attrs["title"] == "" do
      {:noreply, socket}
    else
      case Tasks.create_task(attrs) do
        {:ok, _task} ->
          {:noreply, load_board(socket)}

        {:error, %Ecto.Changeset{} = _changeset} ->
          {:noreply, put_flash(socket, :error, gettext("Could not create task"))}
      end
    end
  end

  # PubSub: refresh the board when tasks change anywhere (other tabs, MCP, API).
  def handle_info({:task_changed, _action, _task}, socket) do
    {:noreply, load_board(socket)}
  end

  def handle_info({:page_changed, _action, _page}, socket) do
    # Pages (projects/plans) don't affect the board, but keep the handler
    # so the shared brain:<id> topic broadcasts don't crash the LiveView.
    {:noreply, socket}
  end

  defp load_board(socket) do
    board = Tasks.list_board(socket.assigns.workspace.id)

    counts =
      Map.new(board, fn {status, tasks} -> {status, length(tasks)} end)

    socket
    |> assign(
      board: board,
      counts: counts,
      page_title: "#{socket.assigns.workspace.name} · #{gettext("Tasks")}"
    )
  end

  def render(assigns) do
    ~H"""
    <div id="task-board" class="px-6 py-8 h-full overflow-x-auto" phx-hook="TaskDnD">
      <div class="flex items-center gap-2 text-sm text-base-content/50 mb-2">
        <.link navigate={~p"/#{@workspace.slug}"} class="hover:underline">
          {@workspace.name}
        </.link>
        <span>/</span>
        <span>{gettext("Tasks")}</span>
      </div>

      <div class="flex items-center justify-between mb-6">
        <h1 class="text-2xl font-bold flex items-center gap-2">
          <.icon name="hero-view-columns" class="size-6 text-primary" />
          {gettext("Tasks")}
        </h1>
        <p class="text-xs text-base-content/40 hidden md:block">
          {gettext("Drag cards between columns")}
        </p>
      </div>

      <div class="flex gap-4 pb-4 items-start">
        <div
          :for={{status, icon, badge_class} <- @columns}
          data-column={status}
          class="flex-1 min-w-[240px] flex flex-col rounded-2xl bg-base-200/40 border border-base-300 overflow-hidden"
        >
          <div class="flex items-center justify-between px-3 py-2.5 border-b border-base-300">
            <div class="flex items-center gap-2">
              <.icon name={icon} class="size-4 text-base-content/60" />
              <span class="text-sm font-semibold">{column_label(status)}</span>
            </div>
            <span class={"badge badge-sm #{badge_class}"}>
              {Map.get(@counts, status, 0)}
            </span>
          </div>

          <div data-drop-zone class="p-2 space-y-2 min-h-[80px] flex-1">
            <.task_card
              :for={task <- Map.get(@board, status, [])}
              task={task}
              workspace_slug={@workspace.slug}
            />
            <p
              :if={Map.get(@board, status, []) == []}
              class="text-xs text-base-content/30 text-center py-4"
            >
              {gettext("Empty")}
            </p>
          </div>

          <form
            phx-submit="quick_add"
            class="px-2 pb-2"
            id={"quick-add-#{status}"}
          >
            <input
              type="hidden"
              name="task[status]"
              value={status}
            />
            <input
              type="text"
              name="task[title]"
              placeholder={gettext("+ Add task")}
              class="w-full text-xs px-2 py-1.5 rounded-lg bg-base-100 border border-base-300 focus:border-primary/50 focus:outline-none placeholder:text-base-content/30 transition"
            />
          </form>
        </div>
      </div>
    </div>
    """
  end

  # ── Components ──────────────────────────────────────────────────────────

  attr :task, Task, required: true
  attr :workspace_slug, :string, required: true

  defp task_card(assigns) do
    ~H"""
    <div
      data-task-id={@task.id}
      draggable="true"
      class="group p-3 rounded-xl bg-base-100 border border-base-300 shadow-sm hover:shadow-md hover:border-primary/40 transition cursor-grab active:cursor-grabbing"
    >
      <div class="flex items-start justify-between gap-2">
        <div class="font-medium text-sm break-words min-w-0">
          {@task.title}
        </div>
        <span :if={@task.priority} class={priority_badge(@task.priority)}>
          {@task.priority}
        </span>
      </div>

      <div class="flex items-center gap-3 mt-2 text-xs text-base-content/50">
        <span
          :if={@task.due_date}
          class={[
            "flex items-center gap-1",
            overdue?(@task) && "text-error font-medium"
          ]}
        >
          <.icon name="hero-calendar-days" class="size-3.5" />
          {Calendar.strftime(@task.due_date, "%d %b")}
        </span>

        <span
          :if={@task.recurrence != "none"}
          class="flex items-center gap-1"
          title={recurrence_title(@task.recurrence)}
        >
          <.icon name="hero-arrow-path" class="size-3.5" />
        </span>

        <span :if={checklist_progress(@task)} class="flex items-center gap-1">
          <.icon name="hero-list-bullet" class="size-3.5" />
          {checklist_progress(@task)}
        </span>
      </div>
    </div>
    """
  end

  defp priority_badge("urgent"), do: "badge badge-error badge-sm shrink-0"
  defp priority_badge("high"), do: "badge badge-warning badge-sm shrink-0"

  defp priority_badge(priority) when priority in ~w(medium low),
    do: "badge badge-ghost badge-sm shrink-0"

  defp priority_badge(_), do: "badge badge-ghost badge-sm shrink-0"

  defp recurrence_title("daily"), do: gettext("Repeats daily")
  defp recurrence_title("weekly"), do: gettext("Repeats weekly")
  defp recurrence_title("monthly"), do: gettext("Repeats monthly")
  defp recurrence_title(_), do: gettext("Repeats")

  defp column_label("backlog"), do: gettext("Backlog")
  defp column_label("this_week"), do: gettext("This Week")
  defp column_label("today"), do: gettext("Today")
  defp column_label("in_progress"), do: gettext("In Progress")
  defp column_label("done"), do: gettext("Done")
  defp column_label("cancelled"), do: gettext("Cancelled")
  defp column_label(other), do: other

  # Called only when @task.due_date is truthy (template guards with :if).
  defp overdue?(%Task{status: status}) when status in ~w(done cancelled), do: false

  defp overdue?(%Task{due_date: %Date{} = due}) do
    Date.compare(due, Date.utc_today()) == :lt
  end

  defp checklist_progress(%Task{meta: %{"checklist" => checklist}})
       when is_list(checklist) and checklist != [] do
    done = Enum.count(checklist, & &1["done"])
    "#{done}/#{length(checklist)}"
  end

  defp checklist_progress(_), do: nil
end
