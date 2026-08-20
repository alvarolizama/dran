defmodule DranWeb.KanbanLive do
  @moduledoc """
  Kanban board for all notes with kanban_status set. Filters by project/goal
  (combinable). Drag-drop updates kanban_status column.
  """
  use DranWeb, :live_view

  alias Dran.Brain
  alias DranWeb.Plugs.Auth

  @kanban_columns [
    {"backlog", gettext("Backlog"), "bg-base-300"},
    {"this_week", gettext("This Week"), "bg-blue-500/20 text-blue-700"},
    {"today", gettext("Today"), "bg-amber-500/20 text-amber-700"},
    {"in_progress", gettext("In Progress"), "bg-purple-500/20 text-purple-700"},
    {"done", gettext("Done"), "bg-green-500/20 text-green-700"},
    {"cancelled", gettext("Cancelled"), "bg-red-500/20 text-red-700"}
  ]

  @quick_add_statuses [
    {"backlog", gettext("Backlog")},
    {"this_week", gettext("This Week")},
    {"today", gettext("Today")},
    {"in_progress", gettext("In Progress")}
  ]

  @priorities [
    {"low", gettext("Low")},
    {"medium", gettext("Medium")},
    {"high", gettext("High")},
    {"urgent", gettext("Urgent")}
  ]

  @badge_styles %{
    "project" => "bg-blue-100 text-blue-700 hover:bg-blue-200",
    "goal" => "bg-green-100 text-green-700 hover:bg-green-200"
  }

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_user={@current_user}
      workspace_slug={@workspace_slug}
      workspaces={@workspaces}
      active_nav="kanban"
    >
      <div class="flex h-screen flex-col overflow-hidden">
        <div class="flex items-center justify-between px-4 pt-3 pb-2 shrink-0">
          <h1 class="text-xl font-semibold">{gettext("Kanban")}</h1>
          <div class="flex items-center gap-2">
            <button
              type="button"
              phx-click="toggle_form"
              class="btn btn-primary btn-sm"
              aria-expanded={@show_form}
            >
              <.icon name="hero-plus" class="size-4" /> {gettext("Nueva tarea")}
            </button>
          </div>
        </div>

        <%!-- Quick-add inline form --%>
        <form
          :if={@show_form}
          id="kanban-quick-add"
          phx-submit="create_todo"
          class="mx-4 mb-3 p-3 surface-2 rounded-xl shrink-0"
        >
          <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-5 gap-3 items-end">
            <div class="lg:col-span-1">
              <label for="qa-title" class="block text-caption mb-1">{gettext("Title")}</label>
              <input
                id="qa-title"
                type="text"
                name="title"
                required
                placeholder={gettext("What needs to be done?")}
                phx-mounted={JS.focus()}
                class="w-full px-3 py-2 text-sm rounded-lg border border-base-300 bg-base-100 transition-colors duration-150 focus:outline-none focus:ring-1 focus:ring-primary"
              />
            </div>

            <div>
              <label for="qa-priority" class="block text-caption mb-1">{gettext("Priority")}</label>
              <select
                id="qa-priority"
                name="priority"
                class="w-full px-3 py-2 text-sm rounded-lg border border-base-300 bg-base-100 transition-colors duration-150 focus:outline-none focus:ring-1 focus:ring-primary"
              >
                <%= for {value, label} <- @priority_options do %>
                  <option value={value} selected={value == @form["priority"]}>{label}</option>
                <% end %>
              </select>
            </div>

            <div>
              <label for="qa-due" class="block text-caption mb-1">{gettext("Due date")}</label>
              <input
                id="qa-due"
                type="date"
                name="due_date"
                value={@form["due_date"]}
                class="w-full px-3 py-2 text-sm rounded-lg border border-base-300 bg-base-100 transition-colors duration-150 focus:outline-none focus:ring-1 focus:ring-primary"
              />
            </div>

            <div :if={@goal_enabled}>
              <label for="qa-goal" class="block text-caption mb-1">{gettext("Goal")}</label>
              <select
                id="qa-goal"
                name="goal_slug"
                class="w-full px-3 py-2 text-sm rounded-lg border border-base-300 bg-base-100 transition-colors duration-150 focus:outline-none focus:ring-1 focus:ring-primary"
              >
                <%= for {label, value} <- @goal_options do %>
                  <option value={value} selected={value == @form["goal_slug"]}>{label}</option>
                <% end %>
              </select>
            </div>

            <div>
              <label for="qa-status" class="block text-caption mb-1">{gettext("Status")}</label>
              <select
                id="qa-status"
                name="kanban_status"
                class="w-full px-3 py-2 text-sm rounded-lg border border-base-300 bg-base-100 transition-colors duration-150 focus:outline-none focus:ring-1 focus:ring-primary"
              >
                <%= for {value, label} <- @status_options do %>
                  <option value={value} selected={value == @form["kanban_status"]}>{label}</option>
                <% end %>
              </select>
            </div>
          </div>

          <div class="flex gap-2 mt-3">
            <button type="submit" class="btn btn-primary btn-sm">{gettext("Create")}</button>
            <button type="button" phx-click="toggle_form" class="btn btn-ghost btn-sm">
              {gettext("Cancel")}
            </button>
          </div>
        </form>

        <%!-- Filtros combinables --%>
        <div class="flex flex-wrap gap-3 mx-4 mb-3 p-3 rounded-lg bg-base-200/50 border border-base-300 shrink-0">
          <.filter_select
            :if={@goal_enabled}
            label={gettext("Goal")}
            id="filter-goal"
            value={@filter_goal}
            options={@filter_goal_options}
            phx_change="filter_goal"
          />
          <button
            :if={@goal_enabled and @filter_goal != "all"}
            phx-click="clear_filters"
            class="btn btn-ghost btn-sm"
          >
            <.icon name="hero-x-mark" class="size-4" /> Clear
          </button>
          <div class="ml-auto text-sm text-base-content/60 self-center">
            {@filtered_count} todos
          </div>
        </div>

        <%!-- Board --%>
        <div
          class="flex gap-4 overflow-x-auto px-4 pb-4 flex-1 min-h-0"
          phx-hook="KanbanDragDrop"
          id="kanban-board"
        >
          <div
            :for={{status, label, badge_class} <- @kanban_columns}
            data-kanban-status={status}
            class="w-72 flex-1 max-w-md shrink-0 flex flex-col min-h-0 h-full rounded-2xl bg-base-200/40 border border-base-300 overflow-hidden"
          >
            <div class="flex items-center justify-between px-3 py-2.5 border-b border-base-300 shrink-0">
              <div class="flex items-center gap-2">
                <span class={"size-2 rounded-full shrink-0 " <> accent_dot(status)}></span>
                <span class="text-sm font-semibold">{label}</span>
              </div>
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
                class="p-3 rounded-xl bg-base-100 border border-base-300 shadow-sm cursor-grab hover:shadow-md hover:border-primary active:cursor-grabbing transition"
              >
                <div class="font-medium text-sm break-words">{todo.title}</div>

                <%!-- Badges --%>
                <div class="flex flex-wrap items-center gap-1.5 mt-2">
                  <%= for {badge, _idx} <- visible_badges(todo, @context) do %>
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
                </div>

                <div :if={due_date(todo)} class={due_date_class(overdue?(todo))}>
                  <.icon name="hero-calendar-days" class="size-3.5" />
                  {format_due(due_date(todo))}
                </div>

                <div class="flex justify-end mt-2">
                  <button
                    type="button"
                    phx-click="archive_todo"
                    phx-value-slug={todo.slug}
                    onclick="event.stopPropagation();"
                    title={gettext("Archive")}
                    class="p-1 rounded-lg text-base-content/40 hover:text-error hover:bg-error/10 transition-colors shrink-0"
                    data-testid={"archive-btn-" <> todo.slug}
                  >
                    <.icon name="hero-archive-box" class="size-4" />
                  </button>
                </div>
              </div>
              <p
                :if={column_items(@filtered_todos, status) == []}
                class="text-xs text-base-content/30 text-center py-4"
              >
                {gettext("Empty")}
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

    if context do
      socket =
        assign(socket,
          context: context,
          kanban_columns: @kanban_columns,
          badge_styles: @badge_styles,
          filter_goal: "all",
          filter_goal_options: [],
          all_todos: [],
          filtered_todos: [],
          filtered_count: 0,
          show_form: false,
          priority_options: @priorities,
          status_options: @quick_add_statuses,
          goal_options: [{gettext("No goal"), ""}],
          goal_enabled: true,
          form: %{
            "title" => "",
            "priority" => "medium",
            "due_date" => "",
            "goal_slug" => "",
            "kanban_status" => "backlog"
          }
        )

      {:ok, socket}
    else
      {:ok, redirect(socket, to: ~p"/")}
    end
  end

  def handle_params(params, _url, socket) do
    context = socket.assigns.context

    if context do
      all_todos = Brain.list_todos(workspace_id: context.id, limit: 500)

      goal_records = Brain.list_goals(context.id)

      filter_goal = Map.get(params, "goal", "all")

      goal_options =
        [{gettext("No goal"), ""} | Enum.map(goal_records, fn g -> {g.title, g.slug} end)]

      form =
        socket.assigns.form
        |> maybe_set_form_filter("goal_slug", filter_goal)

      socket =
        socket
        |> assign(
          all_todos: all_todos,
          filter_goal: filter_goal,
          filter_goal_options: build_goal_filter_options(goal_records),
          goal_options: goal_options,
          form: form
        )
        |> recompute_filtered_todos()

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  defp maybe_set_form_filter(form, key, filter) when filter in ["all", "none"],
    do: Map.put(form, key, "")

  defp maybe_set_form_filter(form, key, filter), do: Map.put(form, key, filter)

  # ── Filtros ──

  def handle_event("filter_goal", %{"value" => value}, socket) do
    {:noreply, socket |> assign(filter_goal: value) |> recompute_filtered_todos()}
  end

  def handle_event("clear_filters", _params, socket) do
    socket =
      socket
      |> assign(filter_goal: "all")
      |> recompute_filtered_todos()

    {:noreply, socket}
  end

  def handle_event("filter_by_badge", %{"type" => "goal", "slug" => slug}, socket) do
    {:noreply, socket |> assign(filter_goal: slug) |> recompute_filtered_todos()}
  end

  def handle_event("filter_by_badge", _params, socket), do: {:noreply, socket}

  # ── Quick-add ──

  def handle_event("toggle_form", _params, socket) do
    {:noreply, assign(socket, show_form: !socket.assigns.show_form)}
  end

  def handle_event("create_todo", params, socket) do
    context = socket.assigns.context
    title = String.trim(params["title"] || "")

    cond do
      context == nil ->
        {:noreply, put_flash(socket, :error, gettext("No context available."))}

      title == "" ->
        {:noreply, put_flash(socket, :error, gettext("Title is required."))}

      true ->
        priority = params["priority"] || "medium"
        goal_slug = params["goal_slug"] || ""
        due_date = params["due_date"] || ""
        kanban_status = params["kanban_status"] || "backlog"

        # Create as note with kind:todo; goal_slug stays in meta for filtering.
        meta = %{"kind" => "todo"}
        meta = if goal_slug != "", do: Map.put(meta, "goal_slug", goal_slug), else: meta

        attrs = %{
          "workspace_id" => context.id,
          "title" => title,
          "slug" => Dran.Slug.generate(title, context.id, "note"),
          "page_type" => "note",
          "meta" => meta,
          "kanban_status" => kanban_status,
          "priority" => priority,
          "due_date" => if(due_date != "", do: due_date, else: nil)
        }

        case Brain.create_page(attrs) do
          {:ok, _page} ->
            all_todos = Brain.list_todos(workspace_id: context.id, limit: 500)

            socket =
              socket
              |> assign(all_todos: all_todos, show_form: false)
              |> recompute_filtered_todos()
              |> put_flash(:info, gettext("Todo created."))

            {:noreply, socket}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, gettext("Could not create todo."))}
        end
    end
  end

  # ── Drag-drop ──

  def handle_event("move_todo", %{"slug" => slug, "target_status" => status}, socket) do
    context = socket.assigns.context

    if context do
      case Brain.get_page_by_slug(slug, context.id) do
        nil ->
          {:noreply, put_flash(socket, :error, "Todo not found.")}

        todo ->
          case Brain.update_page(todo, %{kanban_status: status}) do
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
    {:noreply, push_navigate(socket, to: ~p"/panel/notes/#{slug}")}
  end

  def handle_event("archive_todo", %{"slug" => slug}, socket) do
    context = socket.assigns.context

    if context do
      case Brain.get_page_by_slug(slug, context.id) do
        nil ->
          {:noreply, put_flash(socket, :error, gettext("Todo not found."))}

        todo ->
          case Brain.archive_page(todo) do
            {:ok, _updated} ->
              all_todos = Brain.list_todos(workspace_id: context.id, limit: 500)

              {:noreply,
               socket
               |> assign(all_todos: all_todos)
               |> recompute_filtered_todos()
               |> put_flash(:info, gettext("Todo archived."))}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, gettext("Could not archive todo."))}
          end
      end
    else
      {:noreply, socket}
    end
  end

  # ── Filter helpers ──

  defp recompute_filtered_todos(socket) do
    todos =
      socket.assigns.all_todos
      |> filter_by_goal_slug(socket.assigns.filter_goal)

    socket
    |> assign(filtered_todos: todos, filtered_count: length(todos))
  end

  defp filter_by_goal_slug(todos, "all"), do: todos

  defp filter_by_goal_slug(todos, slug) do
    Enum.filter(todos, fn t ->
      get_in(t.meta, ["goal_slug"]) == slug
    end)
  end

  defp build_goal_filter_options(goals) do
    [{gettext("All"), "all"}, {gettext("None (orphan)"), "none"}] ++
      Enum.map(goals, fn g -> {g.title, g.slug} end)
  end

  # ── Card helpers ──

  defp kanban_status(page), do: page.kanban_status

  defp column_items(todos, status), do: Enum.filter(todos, fn t -> kanban_status(t) == status end)

  defp column_count(todos, status), do: Enum.count(todos, fn t -> kanban_status(t) == status end)

  defp accent_dot("backlog"), do: "bg-base-content/30"
  defp accent_dot("this_week"), do: "bg-blue-500"
  defp accent_dot("today"), do: "bg-amber-500"
  defp accent_dot("in_progress"), do: "bg-purple-500"
  defp accent_dot("done"), do: "bg-green-500"
  defp accent_dot("cancelled"), do: "bg-red-500"
  defp accent_dot(_), do: "bg-base-content/30"

  defp visible_badges(todo, context) do
    todo
    |> all_badges(context)
    |> Enum.take(2)
    |> Enum.with_index(fn badge, idx -> {badge, idx} end)
  end

  defp all_badges(todo, _context) do
    goal_slug = get_in(todo.meta || %{}, ["goal_slug"])
    maybe_add_badge([], "goal", goal_slug)
  end

  defp maybe_add_badge(list, _type, nil), do: list
  defp maybe_add_badge(list, _type, ""), do: list

  defp maybe_add_badge(list, type, slug) do
    label = String.slice(slug, 0, 12)
    [%{type: type, slug: slug, label: label} | list]
  end

  defp due_date(page), do: page.due_date

  defp overdue?(page) do
    case page.due_date do
      %Date{} = d -> Date.compare(d, Date.utc_today()) == :lt
      _ -> false
    end
  end

  defp format_due(nil), do: ""
  defp format_due(%Date{} = d), do: Calendar.strftime(d, "%b %d")
  defp format_due(s) when is_binary(s), do: s
  defp format_due(_), do: ""

  defp due_date_class(true),
    do: "flex items-center gap-1 mt-1.5 text-[11px] text-red-600 font-medium"

  defp due_date_class(false),
    do: "flex items-center gap-1 mt-1.5 text-[11px] text-base-content/60"

  # ── Filter component ──

  attr :label, :string, required: true
  attr :id, :string, required: true
  attr :value, :string, required: true
  attr :options, :list, required: true
  attr :phx_change, :string, required: true

  defp filter_select(assigns) do
    ~H"""
    <form id={"#{@id}-form"} phx-change={@phx_change} class="flex flex-col">
      <label for={@id} class="text-xs font-medium text-base-content/60 mb-1">{@label}</label>
      <select
        id={@id}
        name="value"
        class="px-2 py-1.5 text-sm rounded-lg border border-base-300 bg-base-100"
      >
        <%= for {label, value} <- @options do %>
          <option value={value} selected={value == @value}>{label}</option>
        <% end %>
      </select>
    </form>
    """
  end
end
