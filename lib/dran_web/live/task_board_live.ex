defmodule DranWeb.TaskBoardLive do
  @moduledoc """
  Interactive task board (kanban) with native HTML5 drag & drop.

  Columns come from `Dran.Task.statuses/0`. Moves go through
  `Dran.Tasks.move_task/3` (optimistic locking + position renumbering).
  A stale lock shows a flash and reloads the board from the server — the
  losing client sees the winner's state instead of silently overwriting it.

  The board also has:

    - an assignee filter (all / unassigned / a specific actor)
    - an agent badge on cards assigned to `kind: "agent"` actors
    - a detail panel (click a card) to edit title/body and archive
  """

  use DranWeb, :live_view

  alias Dran.{Goals, Tasks, Task}

  # Web session identity for attribution: the logged-in user's email
  # (sessions carry the email as `current_user`), resolved through
  # Dran.Auth.resolve_created_by/1 — falls back to "system" when no user.
  defp session_identity(socket) do
    Dran.Auth.resolve_created_by(%{email: socket.assigns[:current_user]})
  end

  @column_meta [
    {"backlog", "hero-inbox", "bg-base-300"},
    {"todo", "hero-list-bullet", "bg-sky-500/20 text-sky-700"},
    {"in_progress", "hero-bolt", "bg-purple-500/20 text-purple-700"},
    {"done", "hero-check-circle", "bg-green-500/20 text-green-700"},
    {"cancelled", "hero-x-circle", "bg-red-500/20 text-red-700"}
  ]

  def mount(%{"workspace_slug" => workspace_slug}, session, socket) do
    workspace = Dran.Knowledge.get_workspace_by_slug(workspace_slug)

    if workspace do
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Dran.PubSub, "brain:#{workspace.id}")
        Phoenix.PubSub.subscribe(Dran.PubSub, "workspace:#{workspace.id}")
      end

      {:ok,
       socket
       |> assign(
         workspace: workspace,
         columns: @column_meta,
         current_user: session["user"],
         filter_actor_id: nil,
         filter_goal_id: nil,
         selected_task: nil,
         detail_form: nil,
         managed_actors: Dran.Actors.list_managed_actors()
       )
       |> load_board()}
    else
      {:ok, push_navigate(socket, to: ~p"/")}
    end
  end

  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  def handle_event("filter_actor", %{"actor_id" => actor_id}, socket) do
    filter =
      case actor_id do
        "" -> nil
        "unassigned" -> "unassigned"
        id when is_binary(id) -> id
        _ -> nil
      end

    {:noreply, socket |> assign(filter_actor_id: filter) |> load_board()}
  end

  def handle_event("filter_goal", %{"goal_id" => goal_id}, socket) do
    filter =
      case goal_id do
        "" -> nil
        id when is_binary(id) -> id
        _ -> nil
      end

    {:noreply, socket |> assign(filter_goal_id: filter) |> load_board()}
  end

  def handle_event("select_task", %{"id" => id}, socket) do
    case fetch_board_task(id, socket) do
      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, gettext("Task not found"))}

      {:ok, task} ->
        {:noreply,
         socket
         |> assign(selected_task: task)
         |> assign(detail_form: to_form(Task.update_changeset(task, %{})))}
    end
  end

  def handle_event("close_detail", _params, socket) do
    {:noreply, assign(socket, selected_task: nil, detail_form: nil)}
  end

  def handle_event("save_detail", %{"task" => params}, socket) do
    case socket.assigns.selected_task do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("No task selected"))}

      task ->
        attrs = %{
          "title" => String.trim(params["title"] || ""),
          "body" => params["body"] || "",
          "updated_by" => session_identity(socket)
        }

        # Empty select = unassign.
        attrs =
          case params["assignee_actor_id"] do
            aid when is_binary(aid) and aid != "" -> Map.put(attrs, "assignee_actor_id", aid)
            _ -> Map.put(attrs, "assignee_actor_id", nil)
          end

        # Empty date = clear due_date.
        attrs =
          case params["due_date"] do
            date when is_binary(date) and date != "" -> Map.put(attrs, "due_date", date)
            _ -> Map.put(attrs, "due_date", nil)
          end

        # Empty select = no priority.
        attrs =
          case params["priority"] do
            p when p in ~w(low medium high urgent) -> Map.put(attrs, "priority", p)
            _ -> Map.put(attrs, "priority", nil)
          end

        case Tasks.update_task(task, attrs) do
          {:ok, updated} ->
            # Goal comes through the grouped select; empty = detach.
            goal_id = params["goal_id"]

            with {:ok, updated} <- Tasks.set_goal(updated, goal_id) do
              {:noreply,
               socket
               |> put_flash(:info, gettext("Task updated"))
               |> assign(selected_task: updated)
               |> assign(detail_form: to_form(Task.update_changeset(updated, %{})))
               |> load_board()}
            else
              {:error, _reason} ->
                {:noreply, put_flash(socket, :error, gettext("Could not set goal"))}
            end

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply, assign(socket, detail_form: to_form(changeset))}
        end
    end
  end

  def handle_event("save_detail", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("No task selected"))}
  end

  def handle_event("toggle_archive", %{"id" => id}, socket) do
    case fetch_board_task(id, socket) do
      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, gettext("Task not found"))}

      {:ok, task} ->
        attrs = %{"archived" => not task.archived, "updated_by" => session_identity(socket)}

        case Tasks.update_task(task, attrs) do
          {:ok, _updated} ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Task archived"))
             |> assign(selected_task: nil, detail_form: nil)
             |> load_board()}

          {:error, %Ecto.Changeset{}} ->
            {:noreply, put_flash(socket, :error, gettext("Could not archive task"))}
        end
    end
  end

  def handle_event("move", %{"id" => id, "to_status" => to_status} = params, socket) do
    case fetch_board_task(id, socket) do
      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, gettext("Task not found"))}

      {:ok, task} ->
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

  def handle_event("quick_add", %{"task" => params}, socket) do
    %{"title" => title, "status" => status} = params

    attrs = %{
      "workspace_id" => socket.assigns.workspace.id,
      "title" => String.trim(title),
      "status" => status,
      "created_by" => session_identity(socket)
    }

    # Assignee: actor id from the board's select (empty = unassigned).
    attrs =
      case params[:assignee_actor_id] || params["assignee_actor_id"] do
        aid when is_binary(aid) and aid != "" -> Map.put(attrs, "assignee_actor_id", aid)
        _ -> attrs
      end

    if attrs["title"] == "" do
      {:noreply, socket}
    else
      case Tasks.create_task(attrs) do
        {:ok, task} ->
          # Re-fetch to get :assignee_actor preloaded for the detail panel.
          task = Tasks.get_task(task.id)

          {:noreply,
           socket
           |> put_flash(:info, gettext("Task created"))
           |> assign(selected_task: task)
           |> assign(detail_form: to_form(Task.update_changeset(task, %{})))
           |> load_board()}

        {:error, %Ecto.Changeset{} = _changeset} ->
          {:noreply, put_flash(socket, :error, gettext("Could not create task"))}
      end
    end
  end

  # The task editor runs with autosave off; if a body_change ever arrives
  # (stale client, future autosave), ignore it instead of crashing.
  def handle_event("body_change", _params, socket) do
    {:noreply, socket}
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
    actor_filter = socket.assigns.filter_actor_id
    goal_filter = socket.assigns.filter_goal_id
    actors = socket.assigns.managed_actors
    tree = Goals.flattened_tree(socket.assigns.workspace.id)

    # Roll-up: a selected goal matches itself plus ALL its descendants at
    # any depth (work rolls up the goal hierarchy).
    visible_goal_ids =
      if goal_filter do
        goal_filter
        |> Goals.descendant_ids(Enum.map(tree, &elem(&1, 0)))
        |> MapSet.new()
        |> MapSet.put(goal_filter)
      end

    board_all =
      socket.assigns.workspace.id
      |> Tasks.list_board()

    # Goal lookup for the whole board (badges + goal filter share this map).
    goals_by_task =
      board_all
      |> Map.values()
      |> List.flatten()
      |> Enum.map(& &1.id)
      |> Tasks.list_linked_goals_by_ids(socket.assigns.workspace.id)

    board =
      Map.new(board_all, fn {status, tasks} ->
        {status,
         Enum.filter(tasks, fn task ->
           visible_actor?(task, actor_filter, actors) and
             visible_goal?(task, visible_goal_ids, goals_by_task)
         end)}
      end)

    counts =
      Map.new(board, fn {status, tasks} -> {status, length(tasks)} end)

    socket
    |> assign(
      board: board,
      counts: counts,
      managed_actors: Dran.Actors.list_managed_actors(),
      goal_tree: tree,
      goals_by_task: goals_by_task,
      page_title: "#{socket.assigns.workspace.name} · #{gettext("Tasks")}"
    )
  end

  # Assignee filter: nil shows everything. An actor matches tasks assigned
  # to them, plus tasks they created with no assignee (attribution name ==
  # actor name — the actor model's join convention). "Unassigned" shows
  # cards with no assignee AND no real creator (orphaned work).
  defp visible_actor?(_task, nil, _actors), do: true

  defp visible_actor?(%Task{assignee_actor_id: nil, created_by: cb}, "unassigned", _actors) do
    is_nil(cb) or cb == "system"
  end

  defp visible_actor?(%Task{assignee_actor_id: nil}, "unassigned", _actors), do: false

  defp visible_actor?(%Task{assignee_actor_id: nil, created_by: cb}, actor_id, actors) do
    case Enum.find(actors, &(&1.id == actor_id)) do
      %{name: name} -> cb == name
      _ -> false
    end
  end

  defp visible_actor?(%Task{assignee_actor_id: assignee_id}, actor_id, _actors) do
    assignee_id == actor_id
  end

  # Goal filter. `nil` shows everything. When a goal is selected, a task is
  # visible if ANY of its linked goals is in the visible set (the selected
  # goal + all its descendants — precomputed in load_board).
  defp visible_goal?(_task, nil, _goals_by_task), do: true

  defp visible_goal?(task, %MapSet{} = visible_ids, goals_by_task) do
    task_goals = Map.get(goals_by_task, task.id, [])

    Enum.any?(task_goals, &MapSet.member?(visible_ids, &1.id))
  end

  defp priority_options, do: ~w(low medium high urgent)

  # The task's current goal (first link wins — set_goal/3 enforces a single
  # goal per task from the UI). Used by card chip and the select's selected
  # option; empty map → nil.
  defp task_goal(_goals_by_task, nil), do: nil

  defp task_goal(goals_by_task, task_id) do
    case Map.get(goals_by_task, task_id, []) do
      [goal | _] -> goal
      [] -> nil
    end
  end

  defp goal_id(nil), do: nil
  defp goal_id(goal), do: goal.id

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
        <div class="flex items-center gap-3">
          <label class="flex items-center gap-2 text-xs text-base-content/60">
            <.icon name="hero-funnel" class="size-3.5" />
            <select
              name="actor_id"
              phx-change="filter_actor"
              id="assignee-filter"
              class="text-xs px-2 py-1.5 rounded-lg bg-base-100 border border-base-300 focus:border-primary/50 focus:outline-none"
            >
              <option value="" selected={is_nil(@filter_actor_id)}>
                {gettext("All assignees")}
              </option>
              <option value="unassigned" selected={@filter_actor_id == "unassigned"}>
                {gettext("Unassigned")}
              </option>
              <.actor_options actors={@managed_actors} selected_id={@filter_actor_id} />
            </select>
          </label>
          <label class="flex items-center gap-2 text-xs text-base-content/60">
            <.icon name="hero-flag" class="size-3.5" />
            <select
              name="goal_id"
              phx-change="filter_goal"
              id="goal-filter"
              class="text-xs px-2 py-1.5 rounded-lg bg-base-100 border border-base-300 focus:border-primary/50 focus:outline-none"
            >
              <option value="" selected={is_nil(@filter_goal_id)}>
                {gettext("All goals")}
              </option>
              <.goal_options tree={@goal_tree} selected_id={@filter_goal_id} />
            </select>
          </label>
        </div>
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
              goals_by_task={@goals_by_task}
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

      <.task_detail
        :if={@selected_task}
        task={@selected_task}
        form={@detail_form}
        managed_actors={@managed_actors}
        goals_by_task={@goals_by_task}
        goal_tree={@goal_tree}
      />
    </div>
    """
  end

  # ── Components ──────────────────────────────────────────────────────────

  # Tasks of other workspaces must be invisible to this LiveView: event
  # params are client-side and forgeable, so every lookup is scoped to the
  # mounted workspace.
  defp fetch_board_task(id, socket) do
    case Tasks.get_task(id) do
      %Task{workspace_id: ws_id} = task ->
        if ws_id == socket.assigns.workspace.id, do: {:ok, task}, else: {:error, :not_found}

      nil ->
        {:error, :not_found}
    end
  end

  attr :task, Task, required: true
  attr :workspace_slug, :string, required: true
  attr :goals_by_task, :map, required: true

  defp task_card(assigns) do
    ~H"""
    <div
      data-task-id={@task.id}
      draggable="true"
      phx-click="select_task"
      phx-value-id={@task.id}
      title={gettext("Click to edit")}
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

      <div
        :if={@task.assignee_actor}
        class="mt-2 flex items-center gap-1 text-xs text-base-content/60"
        title={gettext("Assignee")}
      >
        <.icon
          name={
            if @task.assignee_actor.kind == "agent", do: "hero-cpu-chip", else: "hero-user-circle"
          }
          class="size-3.5"
        />
        {Dran.Actors.Actor.label(@task.assignee_actor)}
        <span
          :if={@task.assignee_actor.kind == "agent"}
          class="badge badge-ghost badge-xs gap-0.5"
        >
          <.icon name="hero-bolt" class="size-2.5" />
          {gettext("agent")}
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

        <span
          :if={goal = task_goal(@goals_by_task, @task.id)}
          class="flex items-center gap-1 min-w-0"
          title={goal.title}
        >
          <.icon name="hero-flag" class="size-3.5 text-green-600 shrink-0" />
          <span class="truncate max-w-[120px]">{goal.title}</span>
        </span>
      </div>
    </div>
    """
  end

  attr :task, Task, required: true
  attr :form, Phoenix.HTML.Form, required: true
  attr :managed_actors, :list, required: true
  attr :goals_by_task, :map, required: true
  attr :goal_tree, :list, required: true

  defp task_detail(assigns) do
    ~H"""
    <div class="fixed inset-y-0 right-0 w-full max-w-md bg-base-100 border-l border-base-300 shadow-2xl z-50 flex flex-col">
      <div class="flex items-center justify-between px-4 py-3 border-b border-base-300">
        <h2 class="font-semibold flex items-center gap-2">
          <.icon name="hero-pencil-square" class="size-4 text-primary" />
          {gettext("Edit task")}
        </h2>
        <button
          type="button"
          phx-click="close_detail"
          class="btn btn-ghost btn-xs btn-circle"
          aria-label={gettext("Close")}
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </div>

      <.form
        for={@form}
        id="task-detail-form"
        phx-submit="save_detail"
        class="flex-1 overflow-y-auto p-4 space-y-4"
      >
        <div>
          <label class="text-xs text-base-content/60">{gettext("Status")}</label>
          <div class="mt-1 flex items-center gap-2 text-sm">
            <span class={"badge badge-sm #{status_badge(@task.status)}"}>{column_label(@task.status)}</span>
            <span :if={@task.priority} class={priority_badge(@task.priority)}>{@task.priority}</span>
          </div>
        </div>

        <div class="grid grid-cols-2 gap-3">
          <label class="block">
            <span class="text-xs text-base-content/60">{gettext("Assignee")}</span>
            <select
              name="task[assignee_actor_id]"
              class="mt-1 w-full text-sm px-2 py-2 rounded-lg bg-base-100 border border-base-300 focus:border-primary/50 focus:outline-none"
            >
              <option value="" selected={is_nil(@task.assignee_actor_id)}>
                {gettext("unassigned")}
              </option>
              <.actor_options actors={@managed_actors} selected_id={@task.assignee_actor_id} />
            </select>
          </label>
          <label class="block">
            <span class="text-xs text-base-content/60">{gettext("Priority")}</span>
            <select
              name="task[priority]"
              class="mt-1 w-full text-sm px-2 py-2 rounded-lg bg-base-100 border border-base-300 focus:border-primary/50 focus:outline-none"
            >
              <option value="" selected={is_nil(@task.priority)}>
                {gettext("none")}
              </option>
              <option
                :for={p <- priority_options()}
                value={p}
                selected={@task.priority == p}
              >
                {p}
              </option>
            </select>
          </label>
        </div>

        <label class="block">
          <span class="text-xs text-base-content/60">{gettext("Goal")}</span>
          <select
            name="task[goal_id]"
            class="mt-1 w-full text-sm px-2 py-2 rounded-lg bg-base-100 border border-base-300 focus:border-primary/50 focus:outline-none"
          >
            <option value="" selected={is_nil(task_goal(@goals_by_task, @task.id))}>
              {gettext("no goal")}
            </option>
            <.goal_options
              tree={@goal_tree}
              selected_id={goal_id(task_goal(@goals_by_task, @task.id))}
            />
          </select>
        </label>

        <label class="block">
          <span class="text-xs text-base-content/60">{gettext("Due date")}</span>
          <input
            type="date"
            name="task[due_date]"
            value={@task.due_date && Date.to_iso8601(@task.due_date)}
            class="mt-1 w-full text-sm px-2 py-2 rounded-lg bg-base-100 border border-base-300 focus:border-primary/50 focus:outline-none"
          />
        </label>

        <.input field={@form[:title]} type="text" label={gettext("Title")} />

        <div>
          <span class="label mb-1 block text-xs text-base-content/60">{gettext("Body")}</span>
          <.markdown_editor
            id={"task-editor-#{@task.id}"}
            body={@task.body || ""}
            workspace_id=""
            autosave={false}
            toolbar={false}
            hidden_field="task[body]"
            min_height="220px"
          />
        </div>

        <div class="flex items-center justify-between pt-2">
          <button
            type="button"
            phx-click="toggle_archive"
            phx-value-id={@task.id}
            class="btn btn-ghost btn-sm text-base-content/60"
          >
            <.icon name="hero-archive-box-arrow-down" class="size-4" />
            {gettext("Archive")}
          </button>
          <button type="submit" class="btn btn-primary btn-sm">
            <.icon name="hero-check" class="size-4" />
            {gettext("Save")}
          </button>
        </div>
      </.form>
    </div>
    """
  end

  defp status_badge("backlog"), do: "bg-base-300"
  defp status_badge("todo"), do: "bg-sky-500/20 text-sky-700"
  defp status_badge("in_progress"), do: "bg-purple-500/20 text-purple-700"
  defp status_badge("done"), do: "bg-green-500/20 text-green-700"
  defp status_badge(_), do: "bg-red-500/20 text-red-700"

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
  defp column_label("todo"), do: gettext("To Do")
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
