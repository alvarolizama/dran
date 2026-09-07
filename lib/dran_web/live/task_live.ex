defmodule DranWeb.TaskLive do
  @moduledoc """
  Task detail page — `/:workspace_slug/tasks/:id` with `?edit=true`.

  Same resource pattern as goals and pages: view mode renders badges +
  the markdown body (Mermaid included), Edit switches to an in-page form
  (Tiptap body, assignee/priority/goal/due selects). The board now opens
  the edit modal (`/tasks?task=<id>`) as the primary edit surface; this
  page stays as the deep-link fallback for old URLs, bookmarks and links
  that land directly on `/tasks/:id`.
  """

  use DranWeb, :live_view

  alias Dran.{Goals, Tasks, Task}
  alias DranWeb.Plugs.Auth

  # Web session identity for attribution (same contract as the board).
  defp session_identity(socket) do
    Dran.Auth.resolve_created_by(%{email: socket.assigns[:current_user]})
  end

  @impl true
  def mount(params, session, socket) do
    {socket, context} = Auth.assign_to_socket(socket, session, params)

    if context && connected?(socket) do
      Phoenix.PubSub.subscribe(Dran.PubSub, "brain:#{context.id}")
      # task_changed broadcasts live on the workspace topic (see
      # Dran.Tasks.broadcast_task_change) — without this the live-refresh
      # handler below is unreachable.
      Phoenix.PubSub.subscribe(Dran.PubSub, "workspace:#{context.id}")
    end

    {:ok, assign(socket, active_nav: "tasks")}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {socket, context} = Auth.resolve_workspace(socket, params)

    case {context, params["id"]} do
      {nil, _} ->
        {:noreply, push_navigate(socket, to: ~p"/")}

      {%{id: ws_id, slug: slug} = _context, id} when is_binary(id) ->
        # The id comes from the URL — anything non-UUID (scanners, typos)
        # must redirect to the board, not crash the LiveView with an
        # Ecto.Query.CastError (binary_id cast).
        case Ecto.UUID.cast(id) do
          {:ok, uuid} -> load_task(socket, uuid, ws_id, slug, params)
          :error -> {:noreply, push_navigate(socket, to: ~p"/#{slug}/tasks")}
        end

      _ ->
        {:noreply, push_navigate(socket, to: ~p"/")}
    end
  end

  defp load_task(socket, id, ws_id, slug, params) do
    case Tasks.get_task(id) do
      %Task{workspace_id: ^ws_id} = task ->
        current_goal =
          case Tasks.list_linked_goals(task) do
            [goal | _] -> goal
            [] -> nil
          end

        {:noreply,
         socket
         |> assign(
           task: task,
           goal: current_goal,
           goal_tree: Goals.flattened_tree(ws_id),
           editing: params["edit"] == "true",
           form: to_form(Task.update_changeset(task, %{}), as: :task),
           page_title: task.title
         )}

      _ ->
        # Not found or belongs to another workspace — back to the board.
        {:noreply, push_navigate(socket, to: ~p"/#{slug}/tasks")}
    end
  end

  # Live refresh: the task changed elsewhere (board, MCP, API) — reload it.
  @impl true
  def handle_info({:task_changed, _action, %{id: changed_id}}, socket) do
    if socket.assigns[:task] && socket.assigns.task.id == changed_id do
      case Tasks.get_task(changed_id) do
        %Task{} = task ->
          current_goal =
            case Tasks.list_linked_goals(task) do
              [goal | _] -> goal
              [] -> nil
            end

          {:noreply,
           assign(socket,
             task: task,
             goal: current_goal,
             form: to_form(Task.update_changeset(task, %{}), as: :task)
           )}

        nil ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

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
      <div class="p-6 overflow-y-auto w-full">
        <div>
          <.resource_header
            title={@task.title}
            icon="hero-check-circle"
            back_label={gettext("Board")}
            back_href={~p"/#{@workspace_slug}/tasks"}
          >
            <:actions>
              <.link
                :if={not @editing}
                patch={~p"/#{@workspace_slug}/tasks/#{@task.id}?edit=true"}
                class="btn btn-ghost btn-sm"
              >
                <.icon name="hero-pencil" class="size-4" /> {gettext("Edit")}
              </.link>
              <.link
                :if={@editing}
                patch={~p"/#{@workspace_slug}/tasks/#{@task.id}"}
                class="btn btn-ghost btn-sm"
              >
                <.icon name="hero-eye" class="size-4" /> {gettext("View")}
              </.link>
            </:actions>
          </.resource_header>

          <div class="flex flex-wrap gap-2 mb-5">
            <span class={["badge badge-sm", status_badge(@task.status)]}>
              {status_label(@task.status)}
            </span>
            <span :if={@task.priority} class={["badge badge-sm", priority_badge(@task.priority)]}>
              {@task.priority}
            </span>
            <span
              :if={@task.assignee_actor}
              class="badge badge-sm badge-ghost gap-1"
            >
              <.icon
                name={
                  if @task.assignee_actor.kind == "agent",
                    do: "hero-cpu-chip",
                    else: "hero-user-circle"
                }
                class="size-3"
              />
              {Dran.Actors.Actor.label(@task.assignee_actor)}
            </span>
            <span :if={@task.due_date} class="badge badge-sm badge-ghost gap-1">
              <.icon name="hero-calendar-days" class="size-3" />
              {Calendar.strftime(@task.due_date, "%d %b %Y")}
            </span>
            <span :if={@goal} class="badge badge-sm badge-ghost gap-1" title={@goal.title}>
              <.icon name="hero-flag" class="size-3 text-green-600" />
              {@goal.title}
            </span>
          </div>

          <%= if @editing do %>
            <.form for={@form} id="task-edit-form" phx-submit="save" class="space-y-4">
              <.input field={@form[:title]} type="text" label={gettext("Title")} />

              <div class="grid grid-cols-2 gap-4">
                <label class="block">
                  <span class="text-xs text-base-content/60">{gettext("Assignee")}</span>
                  <select
                    name="task[assignee_actor_id]"
                    class="select select-sm select-bordered w-full mt-1"
                  >
                    <option value="" selected={is_nil(@task.assignee_actor_id)}>
                      {gettext("unassigned")}
                    </option>
                    <.actor_options
                      actors={Dran.Actors.list_managed_actors()}
                      selected_id={@task.assignee_actor_id}
                    />
                  </select>
                </label>
                <label class="block">
                  <span class="text-xs text-base-content/60">{gettext("Priority")}</span>
                  <select
                    name="task[priority]"
                    class="select select-sm select-bordered w-full mt-1"
                  >
                    <option value="" selected={is_nil(@task.priority)}>{gettext("none")}</option>
                    <option
                      :for={p <- Task.priorities()}
                      value={p}
                      selected={@task.priority == p}
                    >
                      {p}
                    </option>
                  </select>
                </label>
                <label class="block">
                  <span class="text-xs text-base-content/60">{gettext("Goal")}</span>
                  <select
                    name="task[goal_id]"
                    class="select select-sm select-bordered w-full mt-1"
                  >
                    <option value="" selected={is_nil(@goal)}>{gettext("no goal")}</option>
                    <.goal_options tree={@goal_tree} selected_id={@goal && @goal.id} />
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
              </div>

              <.markdown_body_field
                id={"task-editor-#{@task.id}"}
                body={@task.body || ""}
                workspace_id={@task.workspace_id}
                hidden_field="task[body]"
              />

              <.form_actions submit_label={gettext("Save")} cancel_event="cancel_edit">
                <:left>
                  <button
                    type="button"
                    phx-click="toggle_archive"
                    class="btn btn-ghost btn-sm text-base-content/60"
                  >
                    <.icon name="hero-archive-box-arrow-down" class="size-4" />
                    {gettext("Archive")}
                  </button>
                </:left>
              </.form_actions>
            </.form>
          <% else %>
            <div
              :if={@task.body not in [nil, ""]}
              id="task-body"
              class="prose prose-base dark:prose-invert max-w-none"
              phx-hook="Mermaid"
            >
              {render_markdown(@task.body, workspace_id: @task.workspace_id)}
            </div>
            <div
              :if={@task.body in [nil, ""]}
              class="text-sm text-base-content/40 py-8 text-center"
            >
              {gettext("No content yet.")}
            </div>

            <div :if={@task.checklist != []} class="mt-6">
              <span class="label mb-1 block text-xs text-base-content/60">{gettext("Checklist")}</span>
              <ul class="space-y-1">
                <li :for={item <- @task.checklist} class="flex items-center gap-2 text-sm">
                  <.icon
                    name={if item["done"], do: "hero-check-circle", else: "hero-circle"}
                    class={[
                      "size-4 shrink-0",
                      if(item["done"], do: "text-green-600", else: "text-base-content/30")
                    ]}
                  />
                  <span class={if item["done"], do: "line-through text-base-content/50"}>
                    {item["text"]}
                  </span>
                </li>
              </ul>
            </div>
          <% end %>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # ── Events ──────────────────────────────────────────────────────────────

  @impl true
  def handle_event("cancel_edit", _params, socket) do
    {:noreply,
     push_patch(socket, to: ~p"/#{socket.assigns.workspace_slug}/tasks/#{socket.assigns.task.id}")}
  end

  def handle_event("save", %{"task" => params}, socket) do
    task = socket.assigns.task

    %{attrs: attrs, goal_id: goal_id} = DranWeb.ResourceComponents.task_attrs_from_params(params)
    attrs = Map.put(attrs, "updated_by", session_identity(socket))

    with {:ok, updated} <- Tasks.update_task(task, attrs),
         {:ok, updated} <- Tasks.set_goal(updated, goal_id) do
      {:noreply,
       socket
       |> put_flash(:info, gettext("Task updated"))
       |> push_navigate(to: ~p"/#{socket.assigns.workspace_slug}/tasks/#{updated.id}")}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :task))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Could not update task"))}
    end
  end

  def handle_event("toggle_archive", _params, socket) do
    task = socket.assigns.task
    attrs = %{"archived" => not task.archived, "updated_by" => session_identity(socket)}

    case Tasks.update_task(task, attrs) do
      {:ok, _updated} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Task archived"))
         |> push_navigate(to: ~p"/#{socket.assigns.workspace_slug}/tasks")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, gettext("Could not archive task"))}
    end
  end

  # ── Badges (page-local presentation) ────────────────────────────────────

  defp status_badge("backlog"), do: "bg-base-200 text-base-content/70"
  defp status_badge("todo"), do: "bg-sky-500/20 text-sky-700"
  defp status_badge("in_progress"), do: "bg-purple-500/20 text-purple-700"
  defp status_badge("done"), do: "bg-green-500/20 text-green-700"
  defp status_badge(_), do: "bg-red-500/20 text-red-700"

  defp status_label("backlog"), do: gettext("Backlog")
  defp status_label("todo"), do: gettext("To Do")
  defp status_label("in_progress"), do: gettext("In Progress")
  defp status_label("done"), do: gettext("Done")
  defp status_label(other), do: other

  defp priority_badge("urgent"), do: "badge-error"
  defp priority_badge("high"), do: "badge-warning"
  defp priority_badge(_), do: "badge-ghost"
end
