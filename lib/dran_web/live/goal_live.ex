defmodule DranWeb.GoalLive do
  @moduledoc "LiveView for goals: index list + detail view with create/edit."

  use DranWeb, :live_view

  alias Dran.Goals
  alias Dran.Goal
  alias Dran.Tasks
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
                  class={"px-2 py-0.5 text-xs rounded-full " <> goal_status_class(@goal)}
                >
                  {String.capitalize(@goal.status)}
                </span>
              </div>
              <h1 class="text-title break-words">{@goal.title}</h1>
              <p :if={@goal.summary} class="text-sm text-base-content/60 mt-1">
                {@goal.summary}
              </p>
            </div>
            <div class="flex gap-2 shrink-0">
              <.link navigate={~p"/#{@workspace_slug}/goals"} class="btn btn-ghost btn-sm">
                <.icon name="hero-arrow-left" class="size-4" /> {gettext("Back")}
              </.link>
              <.link
                :if={not @editing}
                patch={~p"/#{@workspace_slug}/goals/#{@goal.slug}?edit=true"}
                class="btn btn-ghost btn-sm"
              >
                <.icon name="hero-pencil" class="size-4" /> {gettext("Edit")}
              </.link>
            </div>
          </div>

          <%!-- Body (edit happens in the modal overlay) --%>
          <div
            :if={@goal.body != nil and @goal.body != ""}
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
              <span class="text-base-content/20">·</span>
              <.link
                navigate={~p"/#{@workspace_slug}/workflows/#{@goal.slug}"}
                class="text-xs text-base-content/60 hover:underline"
              >
                {gettext("Ver flujo")}
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

      <div :if={@live_action == :index} class="p-6 overflow-y-auto w-full">
        <div class="flex items-center justify-between mb-4">
          <h1 class="text-title">{gettext("Goals")}</h1>
          <.link
            patch={~p"/#{@workspace_slug}/goals?new=true"}
            class="btn btn-primary btn-sm"
            data-testid="goals-new-goal"
          >
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
              <div :if={goal.summary} class="text-xs text-base-content/60 mt-0.5 truncate">
                {goal.summary}
              </div>
            </div>
          </.link>
        </div>
      </div>

      <.resource_modal
        :if={@modal_form}
        id="goal-resource-modal"
        title={(@modal_goal && @modal_goal.title) || gettext("New Goal")}
        pill={(@modal_goal && "GOAL") || "NEW GOAL"}
        pill_class={
          (@modal_goal && "bg-green-100 text-green-700") || "bg-green-500/15 text-green-600"
        }
        on_close="close_goal_modal"
        form_id="goal-modal-form"
        submit_label={(@modal_goal && gettext("Save changes")) || gettext("Create Goal")}
      >
        <.goal_form_fields
          id="goal-modal-form"
          goal={@modal_goal || %Goal{}}
          changeset={@modal_form}
          workspace_id={(@modal_goal && @modal_goal.workspace_id) || (@context && @context.id)}
        />
      </.resource_modal>
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
       tasks: [],
       # Resource modal state — `?new=true` on the index opens create,
       # `?edit=true` on the show opens edit. Rendered via
       # `<.resource_modal>` (DranWeb.ResourceComponents).
       modal_goal: nil,
       modal_form: nil
     )}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {socket, context} = Auth.resolve_workspace(socket, params)

    socket = assign(socket, params: params, context: context)
    socket = apply_action(socket, socket.assigns.live_action, params)

    {:noreply, open_modal_from_params(socket, params)}
  end

  # `?edit=true` on the show page opens the edit modal over the detail.
  defp open_modal_from_params(%{assigns: %{live_action: :show, goal: %Goal{} = goal}} = socket, %{
         "edit" => "true"
       }) do
    assign(socket,
      editing: true,
      modal_goal: goal,
      modal_form: to_form(Goals.change_goal(goal), as: :goal)
    )
  end

  # `?new=true` (index or any action) opens the create modal.
  defp open_modal_from_params(socket, %{"new" => "true"}) do
    assign(socket,
      modal_goal: nil,
      modal_form: to_form(Goals.change_goal(%Goal{}), as: :goal)
    )
  end

  defp open_modal_from_params(socket, _params), do: clear_modal(socket)

  defp clear_modal(socket) do
    assign(socket, modal_goal: nil, modal_form: nil)
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

  # ──────────────────────────────────────────────────────────────────────────
  # Events — goal resource modal (create + edit)
  # ──────────────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("validate_goal", %{"goal" => params}, socket) do
    goal = socket.assigns.modal_goal || %Goal{}
    changeset = Goals.change_goal(goal, params) |> Map.put(:action, :validate)
    {:noreply, assign(socket, modal_form: to_form(changeset, as: :goal))}
  end

  def handle_event("save_goal", %{"goal" => params}, socket) do
    context = socket.assigns.context
    ws_slug = socket.assigns[:workspace_slug]

    # Whitelist + server-side identity — mirror of task_attrs_from_params.
    # Raw params NEVER reach the changeset: fields like workspace_id,
    # created_by, updated_by, archived, parent_goal_id are forgeable and
    # must be owned by the server (SEC-006 pattern).
    attrs = %{
      "title" => String.trim(params["title"] || ""),
      "summary" => params["summary"],
      "body" => params["body"] || "",
      "status" => params["status"]
    }

    result =
      case socket.assigns.modal_goal do
        nil ->
          if context do
            attrs =
              attrs
              |> Map.put("workspace_id", context.id)
              |> Map.put("created_by", session_identity_goal(socket))
              |> ensure_slug()

            Goals.create_goal(attrs)
          else
            {:error, :no_context}
          end

        goal ->
          attrs = Map.put(attrs, "updated_by", session_identity_goal(socket))
          Goals.update_goal(goal, attrs)
      end

    case result do
      {:ok, _goal} ->
        # Create → close back to the list (the new goal is already there).
        # Update → close back to the detail page (without ?edit=true).
        to =
          case socket.assigns do
            %{live_action: :show, goal: %Goal{slug: slug}} -> ~p"/#{ws_slug}/goals/#{slug}"
            _ -> ~p"/#{ws_slug}/goals"
          end

        {:noreply,
         socket
         |> put_flash(:info, gettext("Goal saved."))
         |> push_patch(to: to)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, modal_form: to_form(changeset, as: :goal))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Could not save goal."))}
    end
  end

  def handle_event("close_goal_modal", _params, socket) do
    ws_slug = socket.assigns[:workspace_slug]

    to =
      case socket.assigns do
        %{live_action: :show, goal: %Goal{slug: slug}} -> ~p"/#{ws_slug}/goals/#{slug}"
        _ -> ~p"/#{ws_slug}/goals"
      end

    {:noreply, push_patch(socket, to: to)}
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

  # Web session identity for attribution: the logged-in user's email,
  # resolved through Dran.Auth.resolve_created_by/1 (same contract as the
  # task board; falls back to "system" when no user).
  defp session_identity_goal(socket) do
    Dran.Auth.resolve_created_by(%{email: socket.assigns[:current_user]})
  end

  defp ensure_slug(%{"slug" => slug} = params) when is_binary(slug) and slug != "", do: params

  defp ensure_slug(%{"title" => title} = params) when is_binary(title) and title != "" do
    Map.put(params, "slug", Dran.Slug.slugify(title))
  end

  defp ensure_slug(params), do: params

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
