defmodule DranWeb.ProjectLive do
  @moduledoc "LiveView for projects: index list + detail view with create/edit."

  use DranWeb, :live_view

  alias Dran.Brain
  alias Dran.Page
  alias DranWeb.Plugs.Auth

  @statuses ~w(draft active on_hold done)
  @priorities ~w(low medium high urgent)

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
                <span class="inline-flex items-center gap-1 text-[11px] font-medium px-2 py-0.5 rounded-full bg-blue-100 text-blue-700">
                  <.icon name="hero-rocket-launch" class="size-3" />
                  {gettext("Project")}
                </span>
                <code class="font-mono text-caption text-base-content/60">{@project.slug}</code>
                <span
                  :if={@project.status}
                  class={"px-2 py-0.5 text-xs rounded-full " <> status_class(@project)}
                >
                  {String.capitalize(@project.status)}
                </span>
              </div>
              <h1 class="text-title break-words">{@project.title}</h1>
              <p :if={@project.description} class="text-sm text-base-content/60 mt-1">
                {@project.description}
              </p>
            </div>
            <div class="flex gap-2 shrink-0">
              <.link navigate={~p"/panel/projects"} class="btn btn-ghost btn-sm">
                <.icon name="hero-arrow-left" class="size-4" /> {gettext("Back")}
              </.link>
              <button :if={not @editing} phx-click="toggle_edit" class="btn btn-ghost btn-sm">
                <.icon name="hero-pencil" class="size-4" /> {gettext("Edit")}
              </button>
              <button :if={@editing} phx-click="toggle_edit" class="btn btn-ghost btn-sm">
                <.icon name="hero-eye" class="size-4" /> {gettext("View")}
              </button>
            </div>
          </div>

          <%!-- Metadata row --%>
          <div class="flex flex-wrap gap-3">
            <div
              :if={@project.priority}
              class="px-3 py-1.5 text-sm rounded-lg bg-base-200 border border-base-300"
            >
              <span class="text-base-content/50">{gettext("Priority")}:</span>
              <span class="font-medium">{String.capitalize(@project.priority)}</span>
            </div>
            <div
              :if={@project.health}
              class={"px-3 py-1.5 text-sm rounded-lg border " <> status_class(@project)}
            >
              <span class="text-base-content/50">{gettext("Health")}:</span>
              <span class="font-medium">{String.capitalize(@project.health)}</span>
            </div>
            <div
              :if={@project.start_date}
              class="px-3 py-1.5 text-sm rounded-lg bg-base-200 border border-base-300"
            >
              <span class="text-base-content/50">{gettext("Start")}:</span>
              <span class="font-medium">{@project.start_date}</span>
            </div>
            <div
              :if={@project.target_date}
              class="px-3 py-1.5 text-sm rounded-lg bg-base-200 border border-base-300"
            >
              <span class="text-base-content/50">{gettext("Target")}:</span>
              <span class="font-medium">{@project.target_date}</span>
            </div>
            <div
              :if={@project.goal_id}
              class="px-3 py-1.5 text-sm rounded-lg bg-base-200 border border-base-300"
            >
              <span class="text-base-content/50">{gettext("Goal")}:</span>
              <span class="font-medium">{@linked_goal_title}</span>
            </div>
          </div>

          <%!-- Edit form or body --%>
          <div :if={@editing} class="surface-2 rounded-xl p-6">
            <.form
              for={@form}
              id="project-edit-form"
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
                  field={@form[:status]}
                  type="select"
                  label={gettext("Status")}
                  options={Enum.map(@statuses, &{String.capitalize(&1), &1})}
                />
                <.input
                  field={@form[:priority]}
                  type="select"
                  label={gettext("Priority")}
                  options={Enum.map(@priorities, &{String.capitalize(&1), &1})}
                />
                <.input
                  field={@form[:health]}
                  type="select"
                  label={gettext("Health")}
                  options={[{"—", ""}, {"Green", "green"}, {"Yellow", "yellow"}, {"Red", "red"}]}
                />
                <.input
                  field={@form[:goal_id]}
                  type="select"
                  label={gettext("Goal")}
                  options={@goal_options}
                />
                <.input field={@form[:start_date]} type="date" label={gettext("Start Date")} />
                <.input field={@form[:target_date]} type="date" label={gettext("Target Date")} />
              </div>

              <div>
                <span class="label mb-1 block text-sm font-medium text-base-content/70">{gettext(
                  "Content"
                )}</span>
                <textarea
                  name="project[body]"
                  rows={8}
                  class="w-full px-3 py-2 text-sm rounded-lg border border-base-300 bg-base-100 font-mono focus:outline-none focus:ring-1 focus:ring-primary"
                >{@project.body}</textarea>
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
            :if={not @editing and @project.body != nil and @project.body != ""}
            class="prose prose-base dark:prose-invert"
          >
            {render_markdown(@project.body, [])}
          </div>
        </div>
      </div>

      <div :if={@live_action == :new} class="p-6 overflow-y-auto w-full max-w-2xl mx-auto">
        <div class="mb-6">
          <h1 class="text-title">{gettext("New Project")}</h1>
          <p class="text-caption mt-1">{gettext("Create a new project to group goals and work.")}</p>
        </div>

        <.form for={@form} id="project-new-form" phx-submit="create" class="space-y-4">
          <.input
            field={@form[:title]}
            type="text"
            label={gettext("Title")}
            placeholder={gettext("Enter a title…")}
            required
          />
          <.input field={@form[:description]} type="textarea" label={gettext("Description")} rows={2} />
          <.input
            field={@form[:status]}
            type="select"
            label={gettext("Status")}
            options={Enum.map(@statuses, &{String.capitalize(&1), &1})}
          />
          <.input
            field={@form[:priority]}
            type="select"
            label={gettext("Priority")}
            options={Enum.map(@priorities, &{String.capitalize(&1), &1})}
          />
          <.input
            field={@form[:goal_id]}
            type="select"
            label={gettext("Goal")}
            options={@goal_options}
          />
          <.input field={@form[:start_date]} type="date" label={gettext("Start Date")} />
          <.input field={@form[:target_date]} type="date" label={gettext("Target Date")} />

          <div class="flex justify-end gap-2 pt-2">
            <.link navigate={~p"/panel/projects"} class="btn btn-ghost btn-sm">{gettext("Cancel")}</.link>
            <button
              type="submit"
              class="btn btn-primary btn-sm"
              phx-disable-with={gettext("Creating…")}
            >
              <.icon name="hero-plus" class="w-4 h-4" /> {gettext("Create Project")}
            </button>
          </div>
        </.form>
      </div>

      <div :if={@live_action == :index} class="p-6 overflow-y-auto w-full">
        <div class="flex items-center justify-between mb-4">
          <h1 class="text-title">{gettext("Projects")}</h1>
          <.link navigate={~p"/panel/projects/new"} class="btn btn-primary btn-sm">
            <.icon name="hero-plus" class="w-4 h-4" /> {gettext("New Project")}
          </.link>
        </div>

        <div :if={@projects == []} class="text-center py-12">
          <div class="text-base-content/40">
            <.icon name="hero-rocket-launch" class="size-12 mx-auto mb-3" />
            <p class="text-sm">{gettext("No projects yet.")}</p>
          </div>
        </div>

        <div class="space-y-2">
          <.link
            :for={project <- @projects}
            navigate={~p"/panel/projects/#{project.slug}"}
            class="flex items-center gap-3 p-3 rounded-xl border border-base-300 hover:bg-base-200 transition cursor-pointer"
          >
            <.icon name="hero-rocket-launch" class="size-5 text-blue-500 shrink-0" />
            <div class="min-w-0 flex-1">
              <div class="font-medium text-sm truncate">{project.title}</div>
              <div :if={project.description} class="text-xs text-base-content/60 mt-0.5 truncate">
                {project.description}
              </div>
            </div>
            <div class="flex items-center gap-2 shrink-0">
              <span
                :if={project.status}
                class={"px-2 py-0.5 text-xs rounded-full " <> status_class(project)}
              >
                {String.capitalize(project.status)}
              </span>
              <span :if={project.target_date} class="text-xs text-base-content/50">{project.target_date}</span>
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
  def mount(_params, session, socket) do
    {socket, context} = Auth.assign_to_socket(socket, session)

    if context && connected?(socket) do
      Phoenix.PubSub.subscribe(Dran.PubSub, "brain:#{context.id}")
    end

    {:ok,
     assign(socket,
       context: context,
       editing: false,
       save_status: "idle",
       active_nav: "projects",
       goal_options: goal_options(context),
       statuses: @statuses,
       priorities: @priorities
     )}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {socket, context} = Auth.resolve_workspace(socket, params)
    socket = assign(socket, params: params, context: context, goal_options: goal_options(context))

    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    projects =
      if socket.assigns.context do
        Brain.list_pages(workspace_id: socket.assigns.context.id, kind: "project", limit: 500)
      else
        []
      end

    assign(socket, projects: projects, editing: false, page_title: gettext("Projects"))
  end

  defp apply_action(socket, :show, %{"slug" => slug} = params) do
    context = socket.assigns.context

    if context do
      case Brain.get_page_by_slug(slug, context.id) do
        nil ->
          push_navigate(socket, to: ~p"/panel/projects")

        project ->
          form = Brain.change_page(project) |> to_form(as: :project)
          linked_goal_title = linked_goal_title(project, context)

          assign(socket,
            project: project,
            form: form,
            linked_goal_title: linked_goal_title,
            editing: Map.get(params, "edit") == "true",
            page_title: project.title
          )
      end
    else
      push_navigate(socket, to: ~p"/panel/projects")
    end
  end

  defp apply_action(socket, :new, _params) do
    changeset = Brain.change_page(%Page{})

    assign(socket,
      form: to_form(changeset, as: :project),
      editing: false,
      page_title: gettext("New Project")
    )
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Events
  # ──────────────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("toggle_edit", _params, socket) do
    project = socket.assigns.project
    editing = !socket.assigns.editing

    if editing do
      {:noreply, push_patch(socket, to: ~p"/panel/projects/#{project.slug}?edit=true")}
    else
      {:noreply, push_patch(socket, to: ~p"/panel/projects/#{project.slug}")}
    end
  end

  def handle_event("validate", %{"project" => project_params}, socket) do
    project = socket.assigns[:project] || %Page{}
    changeset = Brain.change_page(project, project_params) |> Map.put(:action, :validate)
    {:noreply, assign(socket, form: to_form(changeset, as: :project))}
  end

  def handle_event("save", %{"project" => project_params}, socket) do
    project = socket.assigns.project

    case Brain.update_page(project, project_params) do
      {:ok, updated} ->
        form = Brain.change_page(updated) |> to_form(as: :project)

        {:noreply,
         socket
         |> assign(project: updated, form: form, editing: false)
         |> put_flash(:info, gettext("Project updated."))}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :project))}
    end
  end

  def handle_event("create", %{"project" => project_params}, socket) do
    context = socket.assigns.context

    if context do
      attrs =
        project_params
        |> Map.put("workspace_id", context.id)
        |> ensure_slug()

      case Brain.create_page(attrs) do
        {:ok, project} ->
          {:noreply,
           socket
           |> put_flash(:info, gettext("Project created."))
           |> push_navigate(to: ~p"/panel/projects/#{project.slug}")}

        {:error, changeset} ->
          {:noreply, assign(socket, form: to_form(changeset, as: :project))}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("No context available."))}
    end
  end

  def handle_event("delete", _params, socket) do
    project = socket.assigns.project

    case Brain.delete_page(project) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Project deleted."))
         |> push_navigate(to: ~p"/panel/projects")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not delete project."))}
    end
  end

  # ── Helpers ──

  defp goal_options(nil), do: [{gettext("No goal"), ""}]

  defp goal_options(context) do
    [{gettext("No goal"), ""} | Enum.map(Brain.list_goals(context.id), &{&1.title, &1.id})]
  end

  defp linked_goal_title(_project, _context) do
    gettext("—")
  end

  defp ensure_slug(%{"slug" => slug} = params) when is_binary(slug) and slug != "", do: params

  defp ensure_slug(%{"title" => title} = params) when is_binary(title) and title != "" do
    Map.put(params, "slug", Dran.Slug.slugify(title))
  end

  defp ensure_slug(params), do: params

  defp status_class(%{meta: %{"health" => "green"}}), do: "bg-green-100 text-green-700"
  defp status_class(%{meta: %{"health" => "yellow"}}), do: "bg-yellow-100 text-yellow-700"
  defp status_class(%{meta: %{"health" => "red"}}), do: "bg-red-100 text-red-700"
  defp status_class(_), do: "bg-base-300 text-base-content/60"

  # ── PubSub: real-time update when a project changes ──

  @impl true
  def handle_info({:page_changed, _action, changed_project}, socket) do
    if socket.assigns[:project] && socket.assigns.project.id == changed_project.id do
      project = Brain.get_page(changed_project.id)

      if project do
        form = Brain.change_page(project) |> to_form(as: :project)
        {:noreply, assign(socket, project: project, form: form)}
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}
end
