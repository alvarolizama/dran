defmodule DranWeb.GoalLive do
  @moduledoc "LiveView for goals: index list + detail view with create/edit."

  use DranWeb, :live_view

  alias Dran.Goals
  alias Dran.Goal
  alias Dran.Tasks
  alias DranWeb.Plugs.Auth

  @goal_kinds ~w(personal coding business learning health finance other investing marketing product writing career relationship travel)

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
      workspace_slug={@workspace_slug}
      workspaces={@workspaces}
      active_nav={@active_nav}
    >
      <div :if={@live_action == :show} class="p-6 overflow-y-auto w-full">
        <div class="max-w-4xl mx-auto space-y-6">
          <div class="flex items-start justify-between gap-4">
            <div class="min-w-0 flex-1">
              <div class="flex flex-wrap items-center gap-2 mb-2 text-caption">
                <span class="inline-flex items-center gap-1 text-[11px] font-medium px-2 py-0.5 rounded-full bg-green-100 text-green-700">
                  <.icon name="hero-flag" class="size-3" />
                  {gettext("Goal")}
                </span>
                <code class="font-mono text-caption text-base-content/60">{@goal.slug}</code>
                <span
                  :if={@goal.status}
                  class={"px-2 py-0.5 text-xs rounded-full " <> health_class(@goal)}
                >
                  {String.capitalize(@goal.status)}
                </span>
              </div>
              <h1 class="text-title break-words">{@goal.title}</h1>
              <p :if={@goal.description} class="text-sm text-base-content/60 mt-1">
                {@goal.description}
              </p>
            </div>
            <div class="flex gap-2 shrink-0">
              <.link navigate={~p"/#{@workspace_slug}/goals"} class="btn btn-ghost btn-sm">
                <.icon name="hero-arrow-left" class="size-4" /> {gettext("Back")}
              </.link>
              <button
                :if={not @editing}
                phx-click="toggle_edit"
                class="btn btn-ghost btn-sm"
              >
                <.icon name="hero-pencil" class="size-4" /> {gettext("Edit")}
              </button>
              <button
                :if={@editing}
                phx-click="toggle_edit"
                class="btn btn-ghost btn-sm"
              >
                <.icon name="hero-eye" class="size-4" /> {gettext("View")}
              </button>
            </div>
          </div>

          <%!-- Metrics row --%>
          <div class="flex flex-wrap gap-3">
            <div
              :if={@goal.kind}
              class="px-3 py-1.5 text-sm rounded-lg bg-base-200 border border-base-300"
            >
              <span class="text-base-content/50">{gettext("Kind")}:</span>
              <span class="font-medium">{String.capitalize(@goal.kind)}</span>
            </div>
            <div
              :if={@goal.health}
              class={"px-3 py-1.5 text-sm rounded-lg border " <> health_class(@goal)}
            >
              <span class="text-base-content/50">{gettext("Health")}:</span>
              <span class="font-medium">{String.capitalize(@goal.health)}</span>
            </div>
            <div
              :if={@goal.target_date}
              class="px-3 py-1.5 text-sm rounded-lg bg-base-200 border border-base-300"
            >
              <span class="text-base-content/50">{gettext("Target")}:</span>
              <span class="font-medium">{@goal.target_date}</span>
            </div>
            <div
              :if={@goal.metric}
              class="px-3 py-1.5 text-sm rounded-lg bg-base-200 border border-base-300"
            >
              <span class="text-base-content/50">{gettext("Metric")}:</span>
              <span class="font-medium">{@goal.metric}</span>
            </div>
          </div>

          <%!-- Progress bar --%>
          <div :if={@goal.progress != nil} class="surface-2 rounded-xl p-4">
            <div class="flex items-center justify-between mb-2">
              <span class="text-sm font-medium">{gettext("Progress")}</span>
              <span class="text-sm font-semibold">{trunc((@goal.progress || 0) * 100)}%</span>
            </div>
            <div class="h-2 rounded-full bg-base-300 overflow-hidden">
              <div
                class="h-full rounded-full bg-primary transition-all"
                style={"width: #{trunc((@goal.progress || 0) * 100)}%"}
              >
              </div>
            </div>
          </div>

          <%!-- Edit form or body --%>
          <div :if={@editing} class="surface-2 rounded-xl p-6">
            <.form
              for={@form}
              id="goal-edit-form"
              phx-change="validate"
              phx-submit="save"
              class="space-y-4"
            >
              <.input field={@form[:title]} type="text" label={gettext("Title")} />
              <.input field={@form[:slug]} type="text" label={gettext("Slug")} />
              <.input
                field={@form[:description]}
                type="textarea"
                label={gettext("Description")}
                rows={2}
              />

              <div class="grid grid-cols-2 gap-4">
                <.input
                  field={@form[:kind]}
                  type="select"
                  label={gettext("Kind")}
                  options={Enum.map(@goal_kinds, &{String.capitalize(&1), &1})}
                />
                <.input
                  field={@form[:health]}
                  type="select"
                  label={gettext("Health")}
                  options={[{"—", ""}, {"Green", "green"}, {"Yellow", "yellow"}, {"Red", "red"}]}
                />
                <.input
                  field={@form[:status]}
                  type="select"
                  label={gettext("Status")}
                  options={[
                    {"Active", "active"},
                    {"Draft", "draft"},
                    {"On Hold", "on_hold"},
                    {"Done", "done"}
                  ]}
                />
                <.input field={@form[:metric]} type="text" label={gettext("Metric")} />
                <.input field={@form[:target_value]} type="number" label={gettext("Target Value")} />
                <.input field={@form[:current_value]} type="number" label={gettext("Current Value")} />
                <.input field={@form[:unit]} type="text" label={gettext("Unit")} />
                <.input
                  field={@form[:progress]}
                  type="number"
                  label={gettext("Progress (0-1)")}
                  step={0.01}
                  min={0}
                  max={1}
                />
                <.input field={@form[:start_date]} type="date" label={gettext("Start Date")} />
                <.input field={@form[:target_date]} type="date" label={gettext("Target Date")} />
              </div>

              <div>
                <span class="label mb-1 block text-sm font-medium text-base-content/70">{gettext(
                  "Content"
                )}</span>
                <textarea
                  name="goal[body]"
                  rows={8}
                  class="w-full px-3 py-2 text-sm rounded-lg border border-base-300 bg-base-100 font-mono focus:outline-none focus:ring-1 focus:ring-primary"
                >{@goal.body}</textarea>
              </div>

              <div class="flex justify-end gap-2 pt-2">
                <button type="button" phx-click="toggle_edit" class="btn btn-ghost btn-sm">{gettext(
                  "Cancel"
                )}</button>
                <button type="submit" class="btn btn-primary btn-sm">{gettext("Save")}</button>
              </div>
            </.form>
          </div>

          <div
            :if={not @editing and @goal.body != nil and @goal.body != ""}
            class="prose prose-base dark:prose-invert"
          >
            {render_markdown(@goal.body, [])}
          </div>

          <%!-- Linked tasks --%>
          <div :if={@tasks != []} class="surface-2 rounded-xl p-4">
            <div class="flex items-center justify-between mb-3">
              <h3 class="text-sm font-semibold flex items-center gap-2">
                <.icon name="hero-check-circle" class="size-4 text-primary" />
                {gettext("Linked tasks")}
                <span class="badge badge-sm badge-ghost">{length(@tasks)}</span>
              </h3>
              <.link
                navigate={~p"/#{@workspace_slug}/tasks"}
                class="text-xs text-base-content/60 hover:underline"
              >
                {gettext("Open board")}
              </.link>
            </div>
            <ul class="space-y-1.5">
              <li
                :for={task <- @tasks}
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
                <span :if={task.assignee_actor} class="shrink-0 text-xs text-base-content/50">
                  {Dran.Actors.Actor.label(task.assignee_actor)}
                </span>
              </li>
            </ul>
          </div>
        </div>
      </div>

      <div :if={@live_action == :new} class="p-6 overflow-y-auto w-full max-w-2xl mx-auto">
        <div class="mb-6">
          <h1 class="text-title">{gettext("New Goal")}</h1>
          <p class="text-caption mt-1">{gettext("Create a new goal to track progress.")}</p>
        </div>

        <.form for={@form} id="goal-new-form" phx-submit="create" class="space-y-4">
          <.input
            field={@form[:title]}
            type="text"
            label={gettext("Title")}
            placeholder={gettext("Enter a title…")}
            required
          />
          <.input field={@form[:description]} type="textarea" label={gettext("Description")} rows={2} />
          <.input
            field={@form[:kind]}
            type="select"
            label={gettext("Kind")}
            options={Enum.map(@goal_kinds, &{String.capitalize(&1), &1})}
          />
          <.input
            field={@form[:metric]}
            type="text"
            label={gettext("Metric")}
            placeholder={gettext("e.g. revenue, weight, completion %")}
          />
          <.input field={@form[:target_value]} type="number" label={gettext("Target Value")} />
          <.input field={@form[:target_date]} type="date" label={gettext("Target Date")} />

          <div class="flex justify-end gap-2 pt-2">
            <.link navigate={~p"/#{@workspace_slug}/goals"} class="btn btn-ghost btn-sm">{gettext(
              "Cancel"
            )}</.link>
            <button
              type="submit"
              class="btn btn-primary btn-sm"
              phx-disable-with={gettext("Creating…")}
            >
              <.icon name="hero-plus" class="w-4 h-4" /> {gettext("Create Goal")}
            </button>
          </div>
        </.form>
      </div>

      <div :if={@live_action == :index} class="p-6 overflow-y-auto w-full">
        <div class="flex items-center justify-between mb-4">
          <h1 class="text-title">{gettext("Goals")}</h1>
          <.link navigate={~p"/#{@workspace_slug}/goals/new"} class="btn btn-primary btn-sm">
            <.icon name="hero-plus" class="w-4 h-4" /> {gettext("New Goal")}
          </.link>
        </div>

        <div :if={@goals == []} class="text-center py-12">
          <div class="text-base-content/40">
            <.icon name="hero-flag" class="size-12 mx-auto mb-3" />
            <p class="text-sm">{gettext("No goals yet.")}</p>
          </div>
        </div>

        <div class="space-y-2">
          <.link
            :for={goal <- @goals}
            navigate={~p"/#{@workspace_slug}/goals/#{goal.slug}"}
            class="flex items-center gap-3 p-3 rounded-xl border border-base-300 hover:bg-base-200 transition cursor-pointer"
          >
            <.icon name="hero-flag" class="size-5 text-green-500 shrink-0" />
            <div class="min-w-0 flex-1">
              <div class="font-medium text-sm truncate">{goal.title}</div>
              <div :if={goal.description} class="text-xs text-base-content/60 mt-0.5 truncate">
                {goal.description}
              </div>
            </div>
            <div class="flex items-center gap-2 shrink-0">
              <span
                :if={goal.health}
                class={"px-2 py-0.5 text-xs rounded-full " <> health_class(goal)}
              >
                {String.capitalize(goal.health)}
              </span>
              <span :if={goal.target_date} class="text-xs text-base-content/50">{goal.target_date}</span>
            </div>
          </.link>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Lifecycle
  # ──────────────────────────────────────────────────────────────────────────

  @impl true
  def mount(params, session, socket) do
    # The URL slug wins over the session (see Plugs.Auth.assign_to_socket/3).
    {socket, context} = Auth.assign_to_socket(socket, session, params)

    if context && connected?(socket) do
      Phoenix.PubSub.subscribe(Dran.PubSub, "brain:#{context.id}")
      # Task changes broadcast on the workspace topic (Dran.Tasks.broadcast_task_change/3)
      Phoenix.PubSub.subscribe(Dran.PubSub, "workspace:#{context.id}")
    end

    {:ok,
     assign(socket,
       context: context,
       editing: false,
       save_status: "idle",
       active_nav: "goals",
       goal_kinds: @goal_kinds,
       tasks: []
     )}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {socket, context} = Auth.resolve_workspace(socket, params)

    # Preserve editing state across patches (e.g. when toggling edit mode)
    socket = assign(socket, params: params, context: context)

    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    goals =
      if socket.assigns.context do
        Goals.list_goals(socket.assigns.context.id)
      else
        []
      end

    assign(socket, goals: goals, editing: false, page_title: gettext("Goals"))
  end

  defp apply_action(socket, :show, %{"slug" => slug} = params) do
    context = socket.assigns.context

    if context do
      case Goals.get_goal_by_slug(slug, context.id) do
        nil ->
          push_navigate(socket, to: ~p"/#{socket.assigns[:workspace_slug]}/goals")

        goal ->
          form = Goals.change_goal(goal) |> to_form(as: :goal)

          assign(socket,
            goal: goal,
            form: form,
            tasks: Tasks.list_tasks_for_goal(goal),
            editing: Map.get(params, "edit") == "true",
            page_title: goal.title
          )
      end
    else
      push_navigate(socket, to: ~p"/#{socket.assigns[:workspace_slug]}/goals")
    end
  end

  defp apply_action(socket, :new, _params) do
    changeset = Goals.change_goal(%Goal{})

    assign(socket,
      form: to_form(changeset, as: :goal),
      editing: false,
      page_title: gettext("New Goal")
    )
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Events
  # ──────────────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("toggle_edit", _params, socket) do
    goal = socket.assigns.goal
    editing = !socket.assigns.editing

    if editing do
      {:noreply,
       push_patch(socket,
         to: ~p"/#{socket.assigns[:workspace_slug]}/goals/#{goal.slug}?edit=true"
       )}
    else
      {:noreply,
       push_patch(socket, to: ~p"/#{socket.assigns[:workspace_slug]}/goals/#{goal.slug}")}
    end
  end

  def handle_event("validate", %{"goal" => goal_params}, socket) do
    goal = socket.assigns[:goal] || %Goal{}
    changeset = Goals.change_goal(goal, goal_params) |> Map.put(:action, :validate)
    {:noreply, assign(socket, form: to_form(changeset, as: :goal))}
  end

  def handle_event("save", %{"goal" => goal_params}, socket) do
    goal = socket.assigns.goal

    case Goals.update_goal(goal, goal_params) do
      {:ok, updated} ->
        form = Goals.change_goal(updated) |> to_form(as: :goal)

        {:noreply,
         socket
         |> assign(goal: updated, form: form, editing: false)
         |> put_flash(:info, gettext("Goal updated."))}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :goal))}
    end
  end

  def handle_event("create", %{"goal" => goal_params}, socket) do
    context = socket.assigns.context

    if context do
      attrs =
        goal_params
        |> Map.put("workspace_id", context.id)
        |> ensure_slug()

      case Goals.create_goal(attrs) do
        {:ok, goal} ->
          {:noreply,
           socket
           |> put_flash(:info, gettext("Goal created."))
           |> push_navigate(to: ~p"/#{socket.assigns[:workspace_slug]}/goals/#{goal.slug}")}

        {:error, changeset} ->
          {:noreply, assign(socket, form: to_form(changeset, as: :goal))}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("No context available."))}
    end
  end

  def handle_event("delete", _params, socket) do
    goal = socket.assigns.goal

    case Goals.delete_goal(goal) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Goal deleted."))
         |> push_navigate(to: ~p"/#{socket.assigns[:workspace_slug]}/goals")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not delete goal."))}
    end
  end

  # ── Helpers ──

  defp ensure_slug(%{"slug" => slug} = params) when is_binary(slug) and slug != "", do: params

  defp ensure_slug(%{"title" => title} = params) when is_binary(title) and title != "" do
    Map.put(params, "slug", Dran.Slug.slugify(title))
  end

  defp ensure_slug(params), do: params

  defp health_class(%{health: "green"}), do: "bg-green-100 text-green-700"
  defp health_class(%{health: "yellow"}), do: "bg-yellow-100 text-yellow-700"
  defp health_class(%{health: "red"}), do: "bg-red-100 text-red-700"
  defp health_class(_), do: "bg-base-300 text-base-content/60"

  defp dot_class("backlog"), do: "bg-base-300"
  defp dot_class("todo"), do: "bg-sky-500"
  defp dot_class("in_progress"), do: "bg-purple-500"
  defp dot_class("done"), do: "bg-green-500"
  defp dot_class("cancelled"), do: "bg-red-400"
  defp dot_class(_), do: "bg-base-300"

  # ── PubSub: real-time update when a goal changes ──

  @impl true
  def handle_info({:page_changed, _action, changed_goal}, socket) do
    if socket.assigns[:goal] && socket.assigns.goal.id == changed_goal.id do
      goal = Goals.get_goal(changed_goal.id)

      if goal do
        form = Goals.change_goal(goal) |> to_form(as: :goal)
        {:noreply, assign(socket, goal: goal, form: form)}
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  # Tasks linked to the shown goal changed (board, MCP, API) — refresh the
  # linked-tasks section.
  @impl true
  def handle_info({:task_changed, _action, _task}, socket) do
    case socket.assigns[:goal] do
      nil ->
        {:noreply, socket}

      goal ->
        {:noreply, assign(socket, tasks: Tasks.list_tasks_for_goal(goal))}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}
end
