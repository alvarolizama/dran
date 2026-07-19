defmodule DranWeb.KanbanLive do
  @moduledoc """
  Global kanban board for all todos. Filters by project_slug, goal_slug,
  plan_slug (combinable). Drag-drop updates kanban_status.
  """
  use DranWeb, :live_view

  alias Dran.Brain
  alias DranWeb.Plugs.Auth

  @kanban_columns [
    {"backlog", "Backlog", "bg-base-300"},
    {"this_week", "This Week", "bg-blue-500/20 text-blue-700"},
    {"today", "Today", "bg-amber-500/20 text-amber-700"},
    {"in_progress", "In Progress", "bg-purple-500/20 text-purple-700"},
    {"done", "Done", "bg-green-500/20 text-green-700"},
    {"cancelled", "Cancelled", "bg-red-500/20 text-red-700"}
  ]

  # Badges por tipo de vínculo (Tailwind puro, como en el plan §4.2).
  @badge_styles %{
    "project" => "bg-blue-100 text-blue-700 hover:bg-blue-200",
    "goal" => "bg-green-100 text-green-700 hover:bg-green-200",
    "plan" => "bg-purple-100 text-purple-700 hover:bg-purple-200"
  }

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_user={@current_user}
      context_slug={@context_slug}
      contexts={@contexts}
      active_nav="kanban"
    >
      <div class="flex h-screen flex-col overflow-hidden">
        <div class="flex items-center justify-between px-4 pt-3 pb-2 shrink-0">
          <h1 class="text-xl font-semibold">Kanban</h1>
          <.link navigate={~p"/todos/new"} class="btn btn-primary btn-sm">
            <.icon name="hero-plus" class="size-4" /> New Todo
          </.link>
        </div>

        <%!-- Filtros combinables --%>
        <div class="flex flex-wrap gap-3 mx-4 mb-3 p-3 rounded-lg bg-base-200/50 border border-base-300 shrink-0">
          <.filter_select
            label="Project"
            id="filter-project"
            value={@filter_project}
            options={@filter_project_options}
            phx_change="filter_project"
          />
          <.filter_select
            label="Goal"
            id="filter-goal"
            value={@filter_goal}
            options={@filter_goal_options}
            phx_change="filter_goal"
          />
          <.filter_select
            label="Plan"
            id="filter-plan"
            value={@filter_plan}
            options={@filter_plan_options}
            phx_change="filter_plan"
          />
          <button
            :if={@filter_project != "all" or @filter_goal != "all" or @filter_plan != "all"}
            phx-click="clear_filters"
            class="btn btn-ghost btn-sm"
          >
            <.icon name="hero-x-mark" class="size-4" /> Clear
          </button>
          <div class="ml-auto text-sm text-base-content/60 self-center">
            {@filtered_count} todos
          </div>
        </div>

        <%!-- Board: flex-1 para llenar el alto restante, min-h-0 para que
             overflow-y-auto de las columnas internas funcione contra el
             contenedor y no haga scrollear al wrapper del layout. --%>
        <div
          class="flex gap-4 overflow-x-auto px-4 pb-4 flex-1 min-h-0"
          phx-hook="KanbanDragDrop"
          id="kanban-board"
        >
          <div
            :for={{status, label, badge_class} <- @kanban_columns}
            data-kanban-status={status}
            class="w-72 shrink-0 flex flex-col min-h-0 h-full rounded-lg bg-base-200/40 border border-base-300"
          >
            <div class="flex items-center justify-between px-3 py-2 border-b border-base-300 shrink-0">
              <span class="text-sm font-semibold">{label}</span>
              <span class={"px-2 py-0.5 text-xs rounded-full " <> badge_class}>
                {column_count(@filtered_todos, status)}
              </span>
            </div>
            <div class="p-2 space-y-2 min-h-0 flex-1 overflow-y-auto">
              <div
                :for={todo <- column_items(@filtered_todos, status)}
                data-kanban-slug={todo.slug}
                draggable="true"
                phx-click="show_page"
                phx-value-slug={todo.slug}
                class="p-3 rounded-lg bg-base-100 border border-base-300 shadow-sm cursor-grab hover:shadow-md hover:border-primary/40 active:cursor-grabbing transition"
              >
                <div class="font-medium text-sm break-words">{todo.title}</div>

                <%!-- Badges de vínculos (maximo 2 visibles) --%>
                <div class="flex flex-wrap items-center gap-1.5 mt-2">
                  <%= for {badge, _idx} <- visible_badges(todo) do %>
                    <span
                      class={"px-1.5 py-0.5 text-[11px] rounded cursor-pointer " <> Map.get(@badge_styles, badge.type, "bg-base-300")}
                      title={badge.slug}
                      phx-click="filter_by_badge"
                      phx-value-type={badge.type}
                      phx-value-slug={badge.slug}
                      onclick="event.stopPropagation();"
                    >
                      {badge.label}
                    </span>
                  <% end %>
                  <span
                    :if={extra_badge_count(todo) > 0}
                    class="px-1.5 py-0.5 text-[11px] rounded bg-base-300 text-base-content/60"
                    title={extra_badge_titles(todo)}
                  >
                    +{extra_badge_count(todo)}
                  </span>
                </div>

                <div :if={due_date(todo)} class={due_date_class(overdue?(todo))}>
                  <.icon name="hero-calendar-days" class="size-3.5" />
                  {format_due(due_date(todo))}
                </div>
              </div>
              <p
                :if={column_items(@filtered_todos, status) == []}
                class="text-xs text-base-content/30 text-center py-4"
              >
                Empty
              </p>
            </div>
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
    </Layouts.app>
    """
  end

  def mount(_params, session, socket) do
    {socket, context} = Auth.assign_to_socket(socket, session)

    socket =
      assign(socket,
        context: context,
        kanban_columns: @kanban_columns,
        badge_styles: @badge_styles,
        filter_project: "all",
        filter_goal: "all",
        filter_plan: "all",
        filter_project_options: [],
        filter_goal_options: [],
        filter_plan_options: [],
        all_todos: [],
        filtered_todos: [],
        filtered_count: 0
      )

    {:ok, socket}
  end

  # Lee query params project/goal/plan (§5.4) para que /kanban?project=slug
  # filtre automáticamente al llegar (p.ej. desde ProjectLive).
  def handle_params(params, _url, socket) do
    context = socket.assigns.context

    if context do
      all_todos =
        Brain.list_pages(
          context_id: context.id,
          type: "todo",
          include_body: false,
          limit: 1000
        )

      project_slugs = Brain.list_pages(context_id: context.id, type: "project", limit: 200)
      goal_slugs = Brain.list_pages(context_id: context.id, type: "goal", limit: 200)
      plan_slugs = Brain.list_pages(context_id: context.id, type: "plan", limit: 200)

      socket =
        socket
        |> assign(
          all_todos: all_todos,
          filter_project: Map.get(params, "project", "all"),
          filter_goal: Map.get(params, "goal", "all"),
          filter_plan: Map.get(params, "plan", "all"),
          filter_project_options: build_filter_options(project_slugs),
          filter_goal_options: build_filter_options(goal_slugs),
          filter_plan_options: build_filter_options(plan_slugs)
        )
        |> recompute_filtered_todos()

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # ── Filtros ──

  def handle_event("filter_project", %{"value" => value}, socket) do
    {:noreply, socket |> assign(filter_project: value) |> recompute_filtered_todos()}
  end

  def handle_event("filter_goal", %{"value" => value}, socket) do
    {:noreply, socket |> assign(filter_goal: value) |> recompute_filtered_todos()}
  end

  def handle_event("filter_plan", %{"value" => value}, socket) do
    {:noreply, socket |> assign(filter_plan: value) |> recompute_filtered_todos()}
  end

  def handle_event("clear_filters", _params, socket) do
    socket =
      socket
      |> assign(filter_project: "all", filter_goal: "all", filter_plan: "all")
      |> recompute_filtered_todos()

    {:noreply, socket}
  end

  def handle_event("filter_by_badge", %{"type" => type, "slug" => slug}, socket) do
    socket =
      case type do
        "project" -> assign(socket, filter_project: slug)
        "goal" -> assign(socket, filter_goal: slug)
        "plan" -> assign(socket, filter_plan: slug)
        _ -> socket
      end
      |> recompute_filtered_todos()

    {:noreply, socket}
  end

  # ── Drag-drop ──

  def handle_event("move_todo", %{"slug" => slug, "target_status" => status}, socket) do
    context = socket.assigns.context

    if context do
      case Brain.get_page_by_slug(slug, context.id) do
        nil ->
          {:noreply, put_flash(socket, :error, "Todo not found.")}

        todo ->
          new_meta = Map.put(todo.meta || %{}, "kanban_status", status)

          case Brain.update_page(todo, %{"meta" => new_meta}) do
            {:ok, _updated} ->
              {:noreply, recompute_filtered_todos(socket)}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Could not update todo status.")}
          end
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("show_page", %{"slug" => slug}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/todos/#{slug}")}
  end

  # ── Helpers de filtrado ──

  defp recompute_filtered_todos(socket) do
    todos =
      socket.assigns.all_todos
      |> filter_by_slug(:project, socket.assigns.filter_project)
      |> filter_by_slug(:goal, socket.assigns.filter_goal)
      |> filter_by_slug(:plan, socket.assigns.filter_plan)

    socket
    |> assign(filtered_todos: todos, filtered_count: length(todos))
  end

  defp filter_by_slug(todos, _type, "all"), do: todos

  defp filter_by_slug(todos, type, "none") do
    key = "#{type}_slug"

    Enum.reject(todos, fn t ->
      v = meta_get(t.meta, key)
      v != nil and v != ""
    end)
  end

  defp filter_by_slug(todos, type, slug) do
    key = "#{type}_slug"
    Enum.filter(todos, fn t -> meta_get(t.meta, key) == slug end)
  end

  defp build_filter_options(pages) do
    [{"All", "all"}, {"None (orphan)", "none"}] ++
      Enum.map(pages, fn p -> {p.title, p.slug} end)
  end

  # ── Helpers de card ──

  defp meta_get(meta, key) when is_map(meta), do: Map.get(meta, key)
  defp meta_get(nil, _key), do: nil

  defp kanban_status(page) do
    case meta_get(page.meta, "kanban_status") do
      s when is_binary(s) and s != "" -> s
      _ -> "backlog"
    end
  end

  defp column_items(todos, status) do
    Enum.filter(todos, fn t -> kanban_status(t) == status end)
  end

  defp column_count(todos, status) do
    Enum.count(todos, fn t -> kanban_status(t) == status end)
  end

  # Construye la lista de badges de un todo. Máximo 2 visibles, resto en +N.
  defp visible_badges(todo) do
    todo
    |> all_badges()
    |> Enum.take(2)
    |> Enum.with_index(fn badge, idx -> {badge, idx} end)
  end

  defp all_badges(todo) do
    []
    |> maybe_add_badge("project", meta_get(todo.meta, "project_slug"))
    |> maybe_add_badge("goal", meta_get(todo.meta, "goal_slug"))
    |> maybe_add_badge("plan", meta_get(todo.meta, "plan_slug"))
  end

  defp maybe_add_badge(list, _type, nil), do: list
  defp maybe_add_badge(list, _type, ""), do: list
  defp maybe_add_badge(list, type, slug) do
    label = String.slice(slug, 0, 12)
    [%{type: type, slug: slug, label: label} | list]
  end

  defp extra_badge_count(todo) do
    max(0, length(all_badges(todo)) - 2)
  end

  defp extra_badge_titles(todo) do
    todo
    |> all_badges()
    |> Enum.drop(2)
    |> Enum.map(fn b -> "#{b.type}: #{b.slug}" end)
    |> Enum.join(", ")
  end

  defp due_date(page), do: meta_get(page.meta, "due_date")

  defp overdue?(page) do
    case due_date(page) do
      s when is_binary(s) and s != "" ->
        case Date.from_iso8601(s) do
          {:ok, d} -> Date.compare(d, Date.utc_today()) == :lt
          _ -> false
        end

      _ ->
        false
    end
  end

  defp format_due(nil), do: ""
  defp format_due(""), do: ""

  defp format_due(s) when is_binary(s) do
    case Date.from_iso8601(s) do
      {:ok, d} -> Calendar.strftime(d, "%b %d")
      _ -> s
    end
  end

  defp due_date_class(true),
    do: "flex items-center gap-1 mt-1.5 text-[11px] text-red-600 font-medium"

  defp due_date_class(false),
    do: "flex items-center gap-1 mt-1.5 text-[11px] text-base-content/60"

  # ── Componente de filtro ──

  attr :label, :string, required: true
  attr :id, :string, required: true
  attr :value, :string, required: true
  attr :options, :list, required: true
  attr :phx_change, :string, required: true

  defp filter_select(assigns) do
    ~H"""
    <div class="flex flex-col">
      <label for={@id} class="text-xs font-medium text-base-content/60 mb-1">{@label}</label>
      <select
        id={@id}
        class="px-2 py-1.5 text-sm rounded-lg border border-base-300 bg-base-100"
        phx-change={@phx_change}
      >
        <%= for {label, value} <- @options do %>
          <option value={value} selected={value == @value}>{label}</option>
        <% end %>
      </select>
    </div>
    """
  end
end
