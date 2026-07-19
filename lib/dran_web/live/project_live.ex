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
    {"graph", "Graph"},
    {"overview", "Overview"},
    {"kanban", "Kanban"},
    {"todos", "Todos"},
    {"goals", "Goals"},
    {"plans", "Plans"},
    {"related", "Related"}
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
        >
          <:actions>
            <.link navigate={~p"/projects"} class="btn btn-primary btn-sm">
              <.icon name="hero-arrow-left" class="size-4" /> Back
            </.link>
            <.link navigate={~p"/kanban?project=#{@page.slug}"} class="btn btn-ghost btn-sm">
              <.icon name="hero-view-columns" class="size-4" /> View in Kanban
            </.link>
            <button :if={not @editing} phx-click="toggle_edit" class="btn btn-primary btn-sm">
              <.icon name="hero-pencil" class="size-4" /> Edit
            </button>
            <button :if={@editing} phx-click="save_page" class="btn btn-success btn-sm">
              <.icon name="hero-check" class="size-4" /> Save
            </button>
            <button :if={@editing} phx-click="cancel_edit" class="btn btn-ghost btn-sm">
              <.icon name="hero-x-mark" class="size-4" /> Cancel
            </button>
          </:actions>

          <:tabs>
            <div class="border-b border-base-300 mb-4">
              <div class="flex gap-1">
                <button
                  :for={{tab, label} <- @project_tabs}
                  phx-click="switch_tab"
                  phx-value-tab={tab}
                  class={
                    "px-3 py-2 text-sm font-medium border-b-2 " <>
                      if @active_tab == tab,
                        do: "border-primary text-primary",
                        else:
                          "border-transparent text-base-content/60 hover:text-base-content"
                  }
                >
                  {label}
                </button>
              </div>
            </div>

            <%!-- Overview: dashboard del proyecto — status, stats, relacionados --%>
            <div :if={@active_tab == "overview"}>
              <%= if @editing do %>
                <.page_edit_form
                  form={@form}
                  page={@page}
                  page_type={@page_type}
                  context_id={@context_id}
                  save_status={@save_status}
                  editor_id="project-editor"
                />
              <% else %>
                <%!-- ── Status header: health + status + priority + dates ── --%>
                <div class="flex flex-wrap items-center gap-2 mb-6">
                  <span class={"px-3 py-1 rounded-full text-sm font-medium " <> health_badge_class(@page)}>
                    Health: {String.capitalize(meta_get(@page.meta, "health") || "—")}
                  </span>
                  <span class="text-xs text-base-content/50">
                    {meta_get(@page.meta, "health_source") || "derived"}
                  </span>
                  <span
                    :if={meta_get(@page.meta, "status")}
                    class="px-3 py-1 rounded-full text-sm bg-base-200 text-base-content/80"
                  >
                    {String.capitalize(meta_get(@page.meta, "status"))}
                  </span>
                  <span
                    :if={meta_get(@page.meta, "priority")}
                    class="px-3 py-1 rounded-full text-sm bg-base-200 text-base-content/80"
                  >
                    {String.capitalize(meta_get(@page.meta, "priority"))}
                  </span>
                  <span
                    :if={meta_get(@page.meta, "target_date")}
                    class="px-3 py-1 rounded-full text-sm bg-base-200 text-base-content/60"
                  >
                    <.icon name="hero-calendar-days" class="size-3.5 inline -mt-0.5" />
                    {meta_get(@page.meta, "target_date")}
                  </span>
                </div>

                <%!-- ── Stat cards: todos por status + goals health + plans ── --%>
                <div class="grid grid-cols-2 md:grid-cols-4 gap-3 mb-6">
                  <div class="surface-2 rounded-xl p-4">
                    <div class="text-2xl font-semibold">{length(@project_todos)}</div>
                    <div class="text-xs text-base-content/60 mt-1">
                      Todos · {count_kanban(@project_todos, "done")} done
                    </div>
                    <div
                      :if={length(@project_todos) > 0}
                      class="mt-2 h-1.5 rounded-full bg-base-300 overflow-hidden"
                    >
                      <div
                        class="h-full bg-green-500 rounded-full transition-all"
                        style={"width: #{progress_pct(@project_todos)}%"}
                      />
                    </div>
                  </div>
                  <div class="surface-2 rounded-xl p-4">
                    <div class="text-2xl font-semibold">
                      {count_kanban(@project_todos, "in_progress")}
                    </div>
                    <div class="text-xs text-base-content/60 mt-1">In progress</div>
                    <div class="text-xs text-base-content/40 mt-1">
                      {count_kanban(@project_todos, "today")} today · {count_kanban(
                        @project_todos,
                        "this_week"
                      )} this week
                    </div>
                  </div>
                  <div class="surface-2 rounded-xl p-4">
                    <div class="text-2xl font-semibold">{length(@project_goals)}</div>
                    <div class="text-xs text-base-content/60 mt-1">Goals</div>
                    <div class="flex gap-1.5 mt-2">
                      <span
                        :for={{h, n} <- health_counts(@project_goals)}
                        :if={n > 0}
                        class={"px-1.5 py-0.5 text-[11px] rounded " <> health_dot_class(h)}
                      >
                        {n} {h}
                      </span>
                    </div>
                  </div>
                  <div class="surface-2 rounded-xl p-4">
                    <div class="text-2xl font-semibold">{length(@project_plans)}</div>
                    <div class="text-xs text-base-content/60 mt-1">Plans</div>
                    <div class="text-xs text-base-content/40 mt-1">
                      {count_plan_status(@project_plans, "active")} active
                    </div>
                  </div>
                </div>

                <%!-- ── Body del project (si tiene) ── --%>
                <div
                  :if={@page.body not in [nil, ""]}
                  class="prose prose-base dark:prose-invert max-w-none mb-6"
                >
                  {@rendered_body}
                </div>

                <%!-- ── Listas compactas: goals / plans / notes / todos activos ── --%>
                <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
                  <div>
                    <h3 class="text-caption font-semibold text-base-content/60 uppercase tracking-wider mb-2">
                      Goals ({length(@project_goals)})
                    </h3>
                    <div
                      :for={goal <- Enum.take(@project_goals, 5)}
                      class="flex items-center justify-between py-1.5 text-sm"
                    >
                      <.link
                        navigate={PageTypes.page_show_path(goal)}
                        class="text-primary hover:underline truncate"
                      >
                        {goal.title}
                      </.link>
                      <span class={"ml-2 shrink-0 px-2 py-0.5 text-xs rounded " <> health_class(goal)}>
                        {String.capitalize(meta_get(goal.meta, "health") || "—")}
                      </span>
                    </div>
                    <p :if={@project_goals == []} class="text-sm text-base-content/40">
                      No goals linked.
                    </p>
                  </div>
                  <div>
                    <h3 class="text-caption font-semibold text-base-content/60 uppercase tracking-wider mb-2">
                      Plans ({length(@project_plans)})
                    </h3>
                    <div
                      :for={plan <- Enum.take(@project_plans, 5)}
                      class="flex items-center justify-between py-1.5 text-sm"
                    >
                      <.link
                        navigate={PageTypes.page_show_path(plan)}
                        class="text-primary hover:underline truncate"
                      >
                        {plan.title}
                      </.link>
                      <span class="ml-2 shrink-0 px-2 py-0.5 text-xs rounded bg-base-300 text-base-content/70">
                        {String.capitalize(meta_get(plan.meta, "status") || "draft")}
                      </span>
                    </div>
                    <p :if={@project_plans == []} class="text-sm text-base-content/40">
                      No plans linked.
                    </p>
                  </div>
                  <div>
                    <h3 class="text-caption font-semibold text-base-content/60 uppercase tracking-wider mb-2">
                      Active todos
                    </h3>
                    <div
                      :for={todo <- active_todos(@project_todos)}
                      class="flex items-center justify-between py-1.5 text-sm"
                    >
                      <.link
                        navigate={PageTypes.page_show_path(todo)}
                        class="text-primary hover:underline truncate"
                      >
                        {todo.title}
                      </.link>
                      <span class={"ml-2 shrink-0 px-2 py-0.5 text-xs rounded " <> kanban_status_class(todo)}>
                        {String.capitalize(kanban_status(todo))}
                      </span>
                    </div>
                    <p :if={active_todos(@project_todos) == []} class="text-sm text-base-content/40">
                      Nothing in flight.
                    </p>
                  </div>
                  <div>
                    <h3 class="text-caption font-semibold text-base-content/60 uppercase tracking-wider mb-2">
                      Notes & refs ({length(@project_notes) + length(@project_references)})
                    </h3>
                    <div
                      :for={n <- Enum.take(@project_notes ++ @project_references, 6)}
                      class="py-1 text-sm"
                    >
                      <.link
                        navigate={PageTypes.page_show_path(n)}
                        class="text-primary hover:underline"
                      >
                        {n.title}
                      </.link>
                    </div>
                    <p
                      :if={@project_notes == [] and @project_references == []}
                      class="text-sm text-base-content/40"
                    >
                      No notes or references linked.
                    </p>
                  </div>
                </div>
              <% end %>
            </div>

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
            <div :if={@active_tab == "graph"}>
              <.page_graph id="project-page-graph" nodes={@graph_nodes} edges={@graph_edges} />
            </div>

            <%!-- Related: grid 2col de notes/concepts/entities/references --%>
            <div :if={@active_tab == "related"}>
              <div class="grid grid-cols-2 gap-4">
                <div>
                  <h4 class="text-xs font-semibold text-base-content/60 mb-2">
                    NOTES ({length(@project_notes)})
                  </h4>
                  <div :for={n <- @project_notes} class="text-sm py-1">
                    <.link navigate={PageTypes.page_show_path(n)} class="text-primary hover:underline">
                      {n.title}
                    </.link>
                  </div>
                </div>
                <div>
                  <h4 class="text-xs font-semibold text-base-content/60 mb-2">
                    CONCEPTS ({length(@project_concepts)})
                  </h4>
                  <div :for={c <- @project_concepts} class="text-sm py-1">
                    <.link navigate={PageTypes.page_show_path(c)} class="text-primary hover:underline">
                      {c.title}
                    </.link>
                  </div>
                </div>
                <div>
                  <h4 class="text-xs font-semibold text-base-content/60 mb-2">
                    ENTITIES ({length(@project_entities)})
                  </h4>
                  <div :for={e <- @project_entities} class="text-sm py-1">
                    <.link navigate={PageTypes.page_show_path(e)} class="text-primary hover:underline">
                      {e.title}
                    </.link>
                  </div>
                </div>
                <div>
                  <h4 class="text-xs font-semibold text-base-content/60 mb-2">
                    REFERENCES ({length(@project_references)})
                  </h4>
                  <div :for={r <- @project_references} class="text-sm py-1">
                    <.link navigate={PageTypes.page_show_path(r)} class="text-primary hover:underline">
                      {r.title}
                    </.link>
                  </div>
                </div>
              </div>
            </div>
          </:tabs>
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
       active_tab: "graph",
       editing: false,
       save_status: "idle",
       active_nav: "projects"
     )}
  end

  def handle_params(%{"slug" => slug} = _params, _url, socket) do
    context = socket.assigns.context

    if context do
      case Brain.get_page_by_slug(slug, context.id) do
        nil ->
          {:noreply, push_navigate(socket, to: ~p"/projects")}

        page ->
          relations = Brain.list_relations_for_page(page.id)
          versions = Brain.list_page_versions(page.id)
          logs = Brain.list_log(context_id: context.id, limit: 10)
          %{nodes: graph_nodes, edges: graph_edges} = GraphHelpers.build_page_subgraph(page)

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
             active_tab: "graph",
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
             rendered_body: rendered_body
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

  def handle_event("archive_page", p, s), do: PageEdit.handle_event("archive_page", p, s)
  def handle_event("unarchive_page", p, s), do: PageEdit.handle_event("unarchive_page", p, s)
  def handle_event("toggle_edit", p, s), do: PageEdit.handle_event("toggle_edit", p, s)
  def handle_event("cancel_edit", p, s), do: PageEdit.handle_event("cancel_edit", p, s)
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

  defp progress_pct(todos) do
    active = Enum.reject(todos, fn t -> kanban_status(t) == "cancelled" end)

    case length(active) do
      0 -> 0
      n -> round(count_kanban(active, "done") / n * 100)
    end
  end

  defp active_todos(todos) do
    todos
    |> Enum.filter(fn t -> kanban_status(t) in ["today", "in_progress", "this_week"] end)
    |> Enum.take(6)
  end

  defp health_counts(goals) do
    for h <- ~w(green yellow red) do
      {h, Enum.count(goals, fn g -> meta_get(g.meta, "health") == h end)}
    end
  end

  defp health_dot_class("green"), do: "bg-green-100 text-green-700"
  defp health_dot_class("yellow"), do: "bg-yellow-100 text-yellow-700"
  defp health_dot_class("red"), do: "bg-red-100 text-red-700"
  defp health_dot_class(_), do: "bg-base-300 text-base-content/60"

  defp count_plan_status(plans, status) do
    Enum.count(plans, fn p -> (meta_get(p.meta, "status") || "draft") == status end)
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

  # ── Health badge helpers (for Overview badge + Goals list) ──

  defp health_class(page) do
    case meta_get(page.meta, "health") do
      "green" -> "bg-green-100 text-green-700"
      "yellow" -> "bg-yellow-100 text-yellow-700"
      "red" -> "bg-red-100 text-red-700"
      _ -> "bg-base-300 text-base-content/60"
    end
  end

  defp health_badge_class(page) do
    case meta_get(page.meta, "health") do
      "green" -> "bg-green-500/20 text-green-700"
      "yellow" -> "bg-yellow-500/20 text-yellow-700"
      "red" -> "bg-red-500/20 text-red-700"
      _ -> "bg-base-300 text-base-content/60"
    end
  end
end
