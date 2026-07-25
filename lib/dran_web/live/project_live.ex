defmodule DranWeb.ProjectLive do
  @moduledoc """
  LiveView for project pages: index list + detail view with sub-page tabs.

  Tabs: Overview (project dashboard — status, stat cards, linked items),
  Kanban (column board of the project's todos with drag-drop), Todos,
  Goals, Plans, Graph, Related.
  """

  use DranWeb, :live_view

  alias Dran.Brain
  alias DranWeb.GraphHelpers
  alias DranWeb.PageEdit
  alias DranWeb.PageTypes
  alias DranWeb.Plugs.Auth

  @page_type "project"

  @project_tabs [
    {"kanban", gettext("Kanban")},
    {"todos", gettext("Tareas")},
    {"goals", gettext("Objetivos")},
    {"plans", gettext("Planes")}
  ]

  @kanban_columns [
    {"backlog", "Backlog", "bg-base-300"},
    {"this_week", "This Week", "bg-blue-500/20 text-blue-700"},
    {"today", "Today", "bg-amber-500/20 text-amber-700"},
    {"in_progress", "In Progress", "bg-purple-500/20 text-purple-700"},
    {"done", "Done", "bg-green-500/20 text-green-700"},
    {"cancelled", "Cancelled", "bg-red-500/20 text-red-700"}
  ]

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_user={@current_user}
      context_slug={@context_slug}
      contexts={@contexts}
      active_nav={@active_nav}
    >
      <div :if={@live_action == :show}>
        <.page_detail
          page={@page}
          relations={@relations}
          versions={@versions}
          compare_version={@compare_version}
          logs={@logs}
          context_slug={@context_slug}
          rendered_body={@rendered_body}
          content_hidden={@active_tab not in ["overview", "graph"]}
          graph_active={@active_tab == "graph"}
          editing={@editing}
        >
          <:actions>
            <.link navigate={~p"/projects"} class="btn btn-primary btn-sm">
              <.icon name="hero-arrow-left" class="size-4" /> Back
            </.link>
            <.link navigate={~p"/kanban?project=#{@page.slug}"} class="btn btn-ghost btn-sm">
              <.icon name="hero-view-columns" class="size-4" /> View in Kanban
            </.link>
          </:actions>

          <:attributes>
            <.page_attributes
              form={@form}
              page={@page}
              page_type={@page_type}
              context_id={@context_id}
              editor_id="project-editor"
            />
          </:attributes>

          <:extra_tabs>
            <button
              :for={{tab, label} <- @project_tabs}
              phx-click="switch_tab"
              phx-value-tab={tab}
              class={[
                "px-3 py-2 text-sm font-medium border-b-2 -mb-px transition-colors duration-150",
                @active_tab == tab && "border-primary text-primary",
                @active_tab != tab &&
                  "border-transparent text-base-content/60 hover:text-base-content hover:border-base-content/20"
              ]}
            >
              {label}
            </button>
          </:extra_tabs>

          <:tabs>
            <%!-- Overview: dashboard del proyecto — status, stats, relacionados --%>
            <div :if={@active_tab == "overview"}>
              <.page_edit_form
                form={@form}
                page={@page}
                page_type={@page_type}
                context_id={@context_id}
                save_status={@save_status}
                editor_id="project-editor"
              />
            </div>
          </:tabs>

          <:extra_content>
            <%!-- Kanban: board de columnas solo con los todos del project --%>
            <div :if={@active_tab == "kanban"} class="flex flex-col h-[calc(100vh-16rem)] min-h-0">
              <div class="flex items-center justify-between mb-3 shrink-0">
                <span class="text-sm text-base-content/60">
                  {length(@project_todos)} {gettext("todos in this project")}
                </span>
                <.link navigate={~p"/todos/new"} class="btn btn-primary btn-xs">
                  <.icon name="hero-plus" class="size-3.5" /> {gettext("New Todo")}
                </.link>
              </div>
              <div
                class="flex gap-4 overflow-x-auto pb-4 flex-1 min-h-0"
                phx-hook="KanbanDragDrop"
                id="project-kanban-board"
              >
                <div
                  :for={{status, label, badge_class} <- @kanban_columns}
                  data-kanban-status={status}
                  class="w-72 shrink-0 flex-1 max-w-sm flex flex-col min-h-0 h-full rounded-2xl bg-base-200/40 border border-base-300 overflow-hidden"
                >
                  <div class="flex items-center justify-between px-3 py-2.5 border-b border-base-300 shrink-0">
                    <div class="flex items-center gap-2">
                      <span class={"size-2 rounded-full shrink-0 " <> kanban_accent_dot(status)}></span>
                      <span class="text-sm font-semibold">{label}</span>
                    </div>
                    <span class={"px-2 py-0.5 text-xs rounded-full " <> badge_class}>
                      {count_kanban(@project_todos, status)}
                    </span>
                  </div>
                  <div class="p-2 space-y-2 min-h-0 flex-1 overflow-y-auto">
                    <div
                      :for={todo <- kanban_items(@project_todos, status)}
                      data-kanban-slug={todo.slug}
                      draggable="true"
                      phx-click="show_page"
                      phx-value-slug={todo.slug}
                      class="p-3 rounded-xl bg-base-100 border border-base-300 shadow-sm cursor-grab hover:shadow-md hover:border-primary transition active:cursor-grabbing"
                    >
                      <div class="font-medium text-sm break-words">{todo.title}</div>
                      <div :if={todo.summary} class="text-xs text-base-content/60 mt-1 line-clamp-2">
                        {todo.summary}
                      </div>
                    </div>
                    <p
                      :if={kanban_items(@project_todos, status) == []}
                      class="text-xs text-base-content/30 text-center py-4"
                    >
                      {gettext("Empty")}
                    </p>
                  </div>
                </div>
              </div>
              <script :type={Phoenix.LiveView.ColocatedHook} name=".KanbanDragDrop">
                export default {
                  mounted() {
                    this.draggedSlug = null;
                    const board = this.el;
                    board.addEventListener("dragstart", (e) => {
                      const card = e.target.closest("[data-kanban-slug]");
                      if (card) {
                        this.draggedSlug = card.dataset.kanbanSlug;
                        e.dataTransfer.effectAllowed = "move";
                      }
                    });
                    board.addEventListener("dragover", (e) => {
                      if (e.target.closest("[data-kanban-status]")) {
                        e.preventDefault();
                        e.dataTransfer.dropEffect = "move";
                      }
                    });
                    board.addEventListener("drop", (e) => {
                      const col = e.target.closest("[data-kanban-status]");
                      if (col !== null && this.draggedSlug !== null) {
                        e.preventDefault();
                        this.pushEvent("move_todo", {
                          slug: this.draggedSlug,
                          target_status: col.dataset.kanbanStatus
                        });
                      }
                      this.draggedSlug = null;
                    });
                    board.addEventListener("dragend", () => {
                      this.draggedSlug = null;
                    });
                  }
                }
              </script>
            </div>

            <%!-- Todos: lista plana de todos los todos del project --%>
            <div :if={@active_tab == "todos"}>
              <div class="text-sm text-base-content/60 mb-3">
                {length(@project_todos)} todos linked
              </div>
              <div :for={todo <- @project_todos} class="p-3 rounded-lg border border-base-300 mb-2">
                <div class="flex items-center justify-between">
                  <.link
                    navigate={PageTypes.page_show_path(todo)}
                    class="font-medium text-primary hover:underline"
                  >
                    {todo.title}
                  </.link>
                  <span class={"px-2 py-0.5 text-xs rounded " <> kanban_status_class(todo)}>
                    {String.capitalize(kanban_status(todo))}
                  </span>
                </div>
                <div :if={todo.summary} class="text-xs text-base-content/60 mt-1">
                  {todo.summary}
                </div>
              </div>
              <p :if={@project_todos == []} class="text-sm text-base-content/40">
                No todos linked to this project.
              </p>
            </div>

            <%!-- Goals: lista con health badge --%>
            <div :if={@active_tab == "goals"}>
              <div :for={goal <- @project_goals} class="p-3 rounded-lg border border-base-300 mb-2">
                <div class="flex items-center justify-between">
                  <.link
                    navigate={PageTypes.page_show_path(goal)}
                    class="font-medium text-primary hover:underline"
                  >
                    {goal.title}
                  </.link>
                  <span class={"px-2 py-0.5 text-xs rounded " <> health_class(goal)}>
                    {String.capitalize(meta_get(goal.meta, "health") || "—")}
                  </span>
                </div>
                <div :if={goal.summary} class="text-xs text-base-content/60 mt-1">
                  {goal.summary}
                </div>
              </div>
              <p :if={@project_goals == []} class="text-sm text-base-content/40">
                No goals linked to this project.
              </p>
            </div>

            <%!-- Plans: lista con status + horizon + due_date --%>
            <div :if={@active_tab == "plans"}>
              <div :for={plan <- @project_plans} class="p-3 rounded-lg border border-base-300 mb-2">
                <div class="flex items-center justify-between">
                  <.link
                    navigate={PageTypes.page_show_path(plan)}
                    class="font-medium text-primary hover:underline"
                  >
                    {plan.title}
                  </.link>
                  <span class="px-2 py-0.5 text-xs rounded bg-base-300 text-base-content/70">
                    {String.capitalize(meta_get(plan.meta, "status") || "draft")}
                  </span>
                </div>
                <div class="text-xs text-base-content/60 mt-1 flex gap-3">
                  <span :if={meta_get(plan.meta, "horizon")}>
                    {String.capitalize(meta_get(plan.meta, "horizon"))}
                  </span>
                  <span :if={meta_get(plan.meta, "period")}>
                    {meta_get(plan.meta, "period")}
                  </span>
                  <span :if={meta_get(plan.meta, "due_date")}>
                    Due: {meta_get(plan.meta, "due_date")}
                  </span>
                </div>
              </div>
              <p :if={@project_plans == []} class="text-sm text-base-content/40">
                No plans linked to this project.
              </p>
            </div>

            <%!-- Graph: subgrafo del proyecto --%>
            <div :if={@active_tab == "graph"} class="space-y-4">
              <.page_graph id="project-page-graph" nodes={@graph_nodes} edges={@graph_edges} />
            </div>
          </:extra_content>
        </.page_detail>
      </div>

      <div :if={@live_action != :show}>
        <.page_list
          pages={@pages}
          archived_pages={@archived_pages}
          archived_filter={@archived_filter}
          page_type={@page_type}
          context_slug={@context_slug}
        />
      </div>
    </Layouts.app>
    """
  end

  def mount(_params, session, socket) do
    {socket, context} = Auth.assign_to_socket(socket, session)

    socket =
      if context do
        allow_upload(
          socket,
          :file,
          accept:
            ~w(image/* video/* audio/* application/pdf text/plain text/markdown text/csv text/html application/json application/zip),
          max_file_size: Dran.Uploads.max_size(),
          auto_upload: true,
          progress: &handle_progress/3
        )
      else
        socket
      end

    {:ok,
     assign(socket,
       context: context,
       page_type: @page_type,
       project_tabs: @project_tabs,
       kanban_columns: @kanban_columns,
       active_tab: "overview",
       editing: true,
       save_status: "idle",
       active_nav: "projects"
     )}
  end

  def handle_params(%{"slug" => slug} = params, _url, socket) do
    {socket, context} = Auth.resolve_context(socket, params)

    if context do
      case Brain.get_page_by_slug(slug, context.id) do
        nil ->
          {:noreply, push_navigate(socket, to: ~p"/projects")}

        page ->
          relations = Brain.list_relations_for_page(page.id)
          versions = Brain.list_page_versions(page.id)
          logs = Brain.list_log(context_id: context.id, limit: 10)
          %{nodes: graph_nodes, edges: graph_edges} = GraphHelpers.build_page_subgraph(page)
          form = Brain.change_page(page) |> to_form(as: :page)

          # Preserve active_tab across patch (e.g. when toggling edit mode)
          active_tab = Map.get(socket.assigns, :active_tab, "overview")

          # Sub-páginas vinculadas por meta["project_slug"] == page.slug.
          # Para todos/goals/plans usamos el filter SQL nativo de Brain.list_pages.
          project_todos =
            Brain.list_pages(
              context_id: context.id,
              type: "todo",
              project_slug: page.slug,
              include_body: false,
              limit: 500
            )

          project_goals =
            Brain.list_pages(
              context_id: context.id,
              type: "goal",
              project_slug: page.slug,
              include_body: false,
              limit: 500
            )

          project_plans =
            Brain.list_pages(
              context_id: context.id,
              type: "plan",
              project_slug: page.slug,
              include_body: false,
              limit: 500
            )

          # Para notes/concepts/entities/references cargamos por type y filtramos
          # en memoria por meta["project_slug"] (mismo patrón que goal_live.ex).
          project_notes = filter_by_project_slug(context.id, "note", page.slug)
          project_concepts = filter_by_project_slug(context.id, "concept", page.slug)
          project_entities = filter_by_project_slug(context.id, "entity", page.slug)
          project_references = filter_by_project_slug(context.id, "reference", page.slug)

          rendered_body =
            render_markdown(page.body,
              context_id: page.context_id,
              inline_links: Map.get(page.meta || %{}, "inline_links", [])
            )

          {:noreply,
           assign(socket,
             page: page,
             relations: relations,
             versions: versions,
             compare_version: nil,
             logs: logs,
             page_title: page.title,
             active_tab: active_tab,
             context_id: context.id,
             project_todos: project_todos,
             project_goals: project_goals,
             project_plans: project_plans,
             project_notes: project_notes,
             project_concepts: project_concepts,
             project_entities: project_entities,
             project_references: project_references,
             graph_nodes: graph_nodes,
             graph_edges: graph_edges,
             rendered_body: rendered_body,
             editing: true,
             form: form,
             save_status: "idle"
           )}
      end
    else
      {:noreply, push_navigate(socket, to: ~p"/projects")}
    end
  end

  def handle_params(_params, _url, socket) do
    {pages, archived_pages} =
      if socket.assigns.context do
        {Brain.list_pages(context_id: socket.assigns.context.id, type: @page_type),
         Brain.list_pages(
           context_id: socket.assigns.context.id,
           type: @page_type,
           archived: true,
           limit: 200
         )}
      else
        {[], []}
      end

    {:noreply,
     assign(socket,
       pages: pages,
       archived_pages: archived_pages,
       archived_filter: "all",
       page_title: "Projects"
     )}
  end

  def handle_event("filter_archived", %{"type" => type}, socket) do
    {:noreply, assign(socket, archived_filter: type)}
  end

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, active_tab: tab)}
  end

  def handle_event("show_page", %{"slug" => slug}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/projects/#{slug}")}
  end

  def handle_event("move_todo", %{"slug" => slug, "target_status" => status}, socket) do
    context = socket.assigns.context

    if context do
      case Brain.get_page_by_slug(slug, context.id) do
        nil ->
          {:noreply, put_flash(socket, :error, "Todo not found.")}

        todo ->
          new_meta = Map.put(todo.meta || %{}, "kanban_status", status)

          case Brain.update_page(todo, %{"meta" => new_meta}) do
            {:ok, updated} ->
              todos =
                Enum.map(socket.assigns.project_todos, fn t ->
                  if t.id == updated.id, do: updated, else: t
                end)

              {:noreply, assign(socket, project_todos: todos)}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Could not update todo status.")}
          end
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("node_click", %{"slug" => slug}, socket) do
    {:noreply, node_click(socket, slug)}
  end

  def handle_event("node_drag", %{"id" => id, "x" => x, "y" => y}, socket) do
    {:noreply, node_drag(socket, id, x, y)}
  end

  def handle_event("new_page", _params, socket) do
    {:noreply, push_navigate(socket, to: ~p"/projects/new")}
  end

  def handle_event("delete_page", p, s), do: PageEdit.handle_event("delete_page", p, s)
  def handle_event("archive_page", p, s), do: PageEdit.handle_event("archive_page", p, s)
  def handle_event("unarchive_page", p, s), do: PageEdit.handle_event("unarchive_page", p, s)
  def handle_event("validate_page", p, s), do: PageEdit.handle_event("validate_page", p, s)
  def handle_event("save_page", p, s), do: PageEdit.handle_event("save_page", p, s)
  def handle_event("body_change", p, s), do: PageEdit.handle_event("body_change", p, s)
  def handle_event("field_change", p, s), do: PageEdit.handle_event("field_change", p, s)
  def handle_event("request_upload", p, s), do: PageEdit.handle_event("request_upload", p, s)
  def handle_event("upload_complete", p, s), do: PageEdit.handle_event("upload_complete", p, s)

  # ── Version comparison ──

  def handle_event("compare_version", params, socket),
    do: DranWeb.VersionCompare.handle_event("compare_version", params, socket)

  def handle_event("clear_compare", params, socket),
    do: DranWeb.VersionCompare.handle_event("clear_compare", params, socket)

  defp handle_progress(:file, _entry, socket), do: {:noreply, socket}

  # ── Helpers ──

  # nil-safe access into a page's `meta` map (string keys, as persisted in JSONB).
  # Matches the repo convention (goal_live.ex:621).
  defp meta_get(meta, key), do: get_in(meta, [key])

  # Carga páginas de un type y filtra en memoria por meta["project_slug"].
  defp filter_by_project_slug(context_id, type, project_slug) do
    Brain.list_pages(context_id: context_id, type: type, include_body: false, limit: 500)
    |> Enum.filter(fn p -> meta_get(p.meta, "project_slug") == project_slug end)
  end

  # ── Kanban status helpers (for the simple Todos list) ──

  defp kanban_status(page) do
    case meta_get(page.meta, "kanban_status") do
      s when is_binary(s) and s != "" -> s
      _ -> "backlog"
    end
  end

  defp kanban_items(todos, status), do: Enum.filter(todos, fn t -> kanban_status(t) == status end)
  defp count_kanban(todos, status), do: Enum.count(todos, fn t -> kanban_status(t) == status end)

  # Colored accent dot per kanban column status (matches global kanban vibe).
  defp kanban_accent_dot(status) do
    case status do
      "backlog" -> "bg-base-300"
      "this_week" -> "bg-blue-500"
      "today" -> "bg-amber-500"
      "in_progress" -> "bg-purple-500"
      "done" -> "bg-green-500"
      "cancelled" -> "bg-red-500"
      _ -> "bg-base-300"
    end
  end

  defp kanban_status_class(page) do
    case kanban_status(page) do
      "this_week" -> "bg-blue-100 text-blue-700"
      "today" -> "bg-amber-100 text-amber-700"
      "in_progress" -> "bg-purple-100 text-purple-700"
      "done" -> "bg-green-100 text-green-700"
      "cancelled" -> "bg-red-100 text-red-700"
      _ -> "bg-base-300 text-base-content/70"
    end
  end

  # ── Health badge helpers (for Goals list) ──

  defp health_class(page) do
    case meta_get(page.meta, "health") do
      "green" -> "bg-green-100 text-green-700"
      "yellow" -> "bg-yellow-100 text-yellow-700"
      "red" -> "bg-red-100 text-red-700"
      _ -> "bg-base-300 text-base-content/60"
    end
  end
end
