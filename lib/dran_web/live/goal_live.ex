defmodule DranWeb.GoalLive do
  @moduledoc """
  El detalle de un goal: cabecera, **progreso derivado** (done/total), sus goals
  hijos (`parent_goal_id`) y sus tasks.

  Toda lectura pasa por los contextos con `scope:` resuelto por la política
  única (`Dran.ContentVisibility`): un goal ajeno privado no se abre (navega
  fuera) y el progreso nunca se guarda — se DERIVA de las tasks
  (`Dran.Goals.progress/1`).
  """

  use DranWeb, :live_view

  alias Dran.{Goals, Tasks}
  alias Dran.Goals.Goal
  alias DranWeb.Plugs.Auth

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
      <div :if={@live_action == :index} id="goals-index" class="p-6 overflow-y-auto w-full">
        <h1 class="text-title flex items-center gap-2 mb-6">
          <.icon name="hero-flag" class="size-6 text-primary" /> {gettext("Goals")}
        </h1>

        <p :if={@goals == []} class="text-sm text-base-content/50 py-12 text-center">
          {gettext("No goals yet.")}
        </p>

        <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
          <.link
            :for={goal <- @goals}
            id={"goal-card-#{goal.id}"}
            navigate={~p"/goals/#{goal.id}"}
            class="card bg-base-100 border border-base-300 hover:border-primary/40 transition"
          >
            <div class="card-body p-4">
              <div class="flex items-center gap-2">
                <.icon name="hero-flag" class="size-5 text-green-600 shrink-0" />
                <span class="font-medium truncate">{goal.title}</span>
                <span class={["ml-auto badge badge-sm", goal_status_class(goal)]}>
                  {String.capitalize(goal.status)}
                </span>
              </div>
              <p :if={goal.summary} class="text-xs text-base-content/60 mt-1 truncate">
                {goal.summary}
              </p>
            </div>
          </.link>
        </div>
      </div>

      <div
        :if={@live_action == :show && @goal}
        id="goal-detail"
        class="p-6 overflow-y-auto w-full"
      >
        <div class="space-y-6">
          <div class="flex items-start justify-between gap-4">
            <div class="min-w-0 flex-1">
              <div class="flex flex-wrap items-center gap-2 mb-2">
                <span class="inline-flex items-center gap-1 text-[11px] font-medium px-2 py-0.5 rounded-full bg-green-100 text-green-700">
                  <.icon name="hero-flag" class="size-3" /> {gettext("Goal")}
                </span>
                <span class={["px-2 py-0.5 text-xs rounded-full", goal_status_class(@goal)]}>
                  {String.capitalize(@goal.status)}
                </span>
                <span
                  :if={@goal.horizon}
                  class="px-2 py-0.5 text-xs rounded-full bg-base-200 text-base-content/70"
                >
                  {@goal.horizon}
                </span>
              </div>
              <h1 class="text-title break-words">{@goal.title}</h1>
              <p :if={@goal.summary} class="text-sm text-base-content/60 mt-1">{@goal.summary}</p>
            </div>
            <div class="flex gap-2 shrink-0">
              <.link navigate={~p"/goals"} class="btn btn-ghost btn-sm">
                <.icon name="hero-arrow-left" class="size-4" /> {gettext("Back")}
              </.link>
              <.link
                navigate={~p"/tasks/#{@goal.id}"}
                id="goal-open-board"
                class="btn btn-ghost btn-sm"
              >
                <.icon name="hero-view-columns" class="size-4" /> {gettext("Board")}
              </.link>
            </div>
          </div>

          <div
            :if={@goal.body != nil and @goal.body != ""}
            class="prose prose-base dark:prose-invert max-w-none"
          >
            {render_markdown(@goal.body, [])}
          </div>

          <%!-- Progreso DERIVADO de las tasks: nunca un campo guardado. --%>
          <div class="surface-2 rounded-xl p-4">
            <h3 class="text-sm font-semibold mb-2 flex items-center gap-2">
              <.icon name="hero-chart-bar" class="size-4 text-primary" /> {gettext("Progress")}
            </h3>
            <div id="goal-progress" data-done={@progress.done} data-total={@progress.total}>
              <div class="flex items-center justify-between text-sm mb-1">
                <span class="text-base-content/70">{gettext("Done")}</span>
                <span class="font-medium">{@progress.done}/{@progress.total}</span>
              </div>
              <div class="w-full bg-base-200 rounded-full h-2 overflow-hidden">
                <div class="bg-primary h-2 rounded-full" style={"width: #{@progress.percent}%"}></div>
              </div>
            </div>
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
                <span class="badge badge-sm badge-ghost">{length(@tasks)}</span>
              </h3>
              <.link
                navigate={~p"/tasks/#{@goal.id}"}
                class="text-xs text-base-content/60 hover:underline"
              >
                {gettext("Open board")}
              </.link>
            </div>

            <p :if={@tasks == []} class="text-sm text-base-content/40">
              {gettext("No tasks yet.")}
            </p>

            <ul id="goal-tasks" class="space-y-1.5">
              <li
                :for={task <- @tasks}
                id={"goal-task-#{task.id}"}
                data-status={task.status}
                class="flex items-center gap-2 text-sm py-1.5 px-2 rounded-lg hover:bg-base-200/60 transition"
              >
                <span class={["shrink-0 size-2 rounded-full", dot_class(task.status)]} />
                <span class={[
                  "flex-1 min-w-0 truncate",
                  task.status in ~w(done cancelled) && "line-through text-base-content/40"
                ]}>
                  {task.title}
                </span>
                <span :if={task.due_date} class="shrink-0 text-xs text-base-content/50">
                  {Calendar.strftime(task.due_date, "%d %b")}
                </span>
              </li>
            </ul>
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
       active_nav: "board",
       goals: [],
       goal: nil,
       progress: empty_progress(),
       children: [],
       tasks: []
     )}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    case reader_scope(socket) do
      nil -> push_navigate(socket, to: ~p"/")
      scope -> assign(socket, goals: Goals.list_goals(scope: scope), page_title: gettext("Goals"))
    end
  end

  defp apply_action(socket, :show, %{"id" => id_or_slug}) do
    case reader_scope(socket) do
      nil ->
        push_navigate(socket, to: ~p"/")

      scope ->
        case fetch_goal(id_or_slug, scope) do
          nil ->
            push_navigate(socket, to: ~p"/goals")

          goal ->
            assign(socket,
              goal: goal,
              progress: Goals.progress(goal),
              children: Goals.list_children(goal, scope: scope),
              tasks: Tasks.list_tasks_for_goal(goal, scope: scope),
              page_title: goal.title
            )
        end
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Helpers
  # ──────────────────────────────────────────────────────────────────────────

  defp reader_scope(socket) do
    case socket.assigns[:user] do
      nil -> nil
      user -> Dran.ContentVisibility.resolve(socket.assigns[:context], user, :goal)
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

  defp goal_status_class(%Goal{status: "active"}), do: "bg-green-100 text-green-700"
  defp goal_status_class(%Goal{status: "draft"}), do: "bg-base-200 text-base-content/70"
  defp goal_status_class(%Goal{status: "on_hold"}), do: "bg-yellow-100 text-yellow-700"
  defp goal_status_class(%Goal{status: "done"}), do: "bg-green-100 text-green-700"
  defp goal_status_class(_), do: "bg-base-300 text-base-content/60"

  defp dot_class("backlog"), do: "bg-base-300"
  defp dot_class("todo"), do: "bg-sky-500"
  defp dot_class("in_progress"), do: "bg-purple-500"
  defp dot_class("done"), do: "bg-green-500"
  defp dot_class("cancelled"), do: "bg-red-400"
  defp dot_class(_), do: "bg-base-300"
end
