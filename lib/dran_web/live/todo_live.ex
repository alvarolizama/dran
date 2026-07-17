defmodule DranWeb.TodoLive do
  @moduledoc """
  LiveView for todo pages.

  Index renders a Kanban board with HTML5 drag & drop between six status
  columns. Show renders the shared `page_detail` component plus a row of
  status buttons for quick kanban_status changes.
  """

  use DranWeb, :live_view

  alias Dran.Brain
  alias DranWeb.GraphHelpers
  alias DranWeb.PageEdit
  alias DranWeb.Plugs.Auth
  import DranWeb.TodoHelpers

  @page_type "todo"
  @tabs [{"content", gettext("Content")}, {"graph", gettext("Graph")}]

  @kanban_columns [
    {"backlog", gettext("Backlog"), "bg-base-300"},
    {"this_week", gettext("This Week"), "bg-blue-500/20 text-blue-700"},
    {"today", gettext("Today"), "bg-amber-500/20 text-amber-700"},
    {"in_progress", gettext("In Progress"), "bg-purple-500/20 text-purple-700"},
    {"done", gettext("Done"), "bg-green-500/20 text-green-700"},
    {"cancelled", gettext("Cancelled"), "bg-red-500/20 text-red-700"}
  ]

  @priorities [
    {"low", gettext("Low"), "bg-gray-100 text-gray-600"},
    {"medium", gettext("Medium"), "bg-blue-100 text-blue-700"},
    {"high", gettext("High"), "bg-orange-100 text-orange-700"},
    {"urgent", gettext("Urgent"), "bg-red-100 text-red-700"}
  ]

  # ──────────────────────────────────────────────────────────────────────────
  # Render
  # ──────────────────────────────────────────────────────────────────────────

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_user={@current_user}
      context_slug={@context_slug}
      contexts={@contexts}
    >
      <div :if={@live_action == :index} id="kanban-board" phx-hook=".KanbanBoard" class="p-6">
        <div class="flex items-center justify-between mb-4">
          <h1 class="text-2xl font-bold">{gettext("Todos")}</h1>
          <button class="btn btn-primary btn-sm" phx-click="new_todo">
            <.icon name="hero-plus" class="w-4 h-4" /> {gettext("New Todo")}
          </button>
        </div>

        <form
          :if={@show_form}
          phx-submit="create_todo"
          class="mb-4 p-4 rounded-lg border border-base-300 bg-base-200/50"
        >
          <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-3 items-end">
            <.input
              id="new-todo-title"
              name="title"
              label={gettext("Title")}
              value={@form["title"]}
              placeholder={gettext("What needs to be done?")}
              required
            />
            <.input
              id="new-todo-priority"
              name="priority"
              type="select"
              label={gettext("Priority")}
              value={@form["priority"]}
              options={@priority_options}
            />
            <.input
              id="new-todo-goal"
              name="goal_slug"
              type="select"
              label={gettext("Goal")}
              value={@form["goal_slug"]}
              options={@goal_options}
            />
            <.input
              id="new-todo-due"
              name="due_date"
              type="date"
              label={gettext("Due date")}
              value={@form["due_date"]}
            />
          </div>
          <div class="flex gap-2 mt-3">
            <button type="submit" class="btn btn-primary btn-sm">{gettext("Create")}</button>
            <button type="button" class="btn btn-soft btn-sm" phx-click="new_todo">{gettext("Cancel")}</button>
          </div>
        </form>

        <div class="flex gap-4 overflow-x-auto pb-4">
          <div
            :for={{status, label, badge_class} <- @kanban_columns}
            data-kanban-status={status}
            class="w-72 shrink-0 flex flex-col rounded-lg bg-base-200/40 border border-base-300"
          >
            <div class="flex items-center justify-between px-3 py-2 border-b border-base-300">
              <span class="text-sm font-semibold">{label}</span>
              <span class={"px-2 py-0.5 text-xs rounded-full " <> badge_class}>
                {column_count(@items, status)}
              </span>
            </div>
            <div class="p-2 space-y-2 min-h-[120px] flex-1 overflow-y-auto">
              <div
                :for={item <- column_items(@items, status)}
                data-kanban-slug={item.slug}
                draggable="true"
                phx-click="show_page"
                phx-value-slug={item.slug}
                class="p-3 rounded-lg bg-base-100 border border-base-300 shadow-sm cursor-grab hover:shadow-md hover:border-primary/40 active:cursor-grabbing transition"
              >
                <div class="font-medium text-sm break-words">{item.title}</div>
                <div class="flex flex-wrap items-center gap-1.5 mt-2">
                  <span class={"px-1.5 py-0.5 text-[11px] rounded " <> priority_class(item)}>
                    {priority_label(item)}
                  </span>
                  <span
                    :if={goal_slug(item)}
                    class="px-1.5 py-0.5 text-[11px] rounded bg-base-300 text-base-content/70"
                  >
                    #{goal_slug(item)}
                  </span>
                </div>
                <div
                  :if={due_date(item)}
                  class={due_date_class(overdue?(item))}
                >
                  <.icon name="hero-calendar-days" class="size-3.5" /> {format_due(due_date(item))}
                </div>
              </div>
              <p
                :if={column_items(@items, status) == []}
                class="text-xs text-base-content/30 text-center py-4"
              >
                {gettext("Drop here")}
              </p>
            </div>
          </div>
        </div>
      </div>

      <%!-- Show: page detail with tabs --%>
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
            <.link navigate={~p"/todos"} class="btn btn-primary btn-sm">
              <.icon name="hero-arrow-left" class="size-4" /> {gettext("Back")}
            </.link>
            <button :if={not @editing} phx-click="toggle_edit" class="btn btn-primary btn-sm">
              <.icon name="hero-pencil" class="size-4" /> {gettext("Edit")}
            </button>
            <button :if={@editing} phx-click="save_page" class="btn btn-success btn-sm">
              <.icon name="hero-check" class="size-4" /> {gettext("Save")}
            </button>
            <button :if={@editing} phx-click="cancel_edit" class="btn btn-ghost btn-sm">
              <.icon name="hero-x-mark" class="size-4" /> {gettext("Cancel")}
            </button>
          </:actions>

          <:tabs>
            <.tabs_bar tabs={@tabs} active_tab={@active_tab} />

            <div :if={@active_tab == "content"} class="space-y-4">
              <div class="flex flex-wrap items-center gap-2">
                <span class="text-xs text-base-content/50 mr-1">{gettext("Status:")}</span>
                <button
                  :for={{status, label, badge_class} <- @kanban_columns}
                  phx-click="change_status"
                  phx-value-slug={@page.slug}
                  phx-value-status={status}
                  class={status_button_class(kanban_status(@page), status, badge_class)}
                >
                  {label}
                </button>
              </div>

              <div class="prose prose-base dark:prose-invert max-w-none">
                {@rendered_body}
              </div>

              <%= if @editing do %>
                <.form
                  for={@form}
                  id="page-edit-form"
                  phx-change="validate_page"
                  phx-submit="save_page"
                >
                  <div class="space-y-5 mt-4">
                    <.input
                      field={@form[:title]}
                      type="text"
                      label={gettext("Title")}
                      placeholder={gettext("Enter a title…")}
                      class="text-lg font-medium"
                    />
                    <div class="grid grid-cols-2 gap-4">
                      <.input
                        field={@form[:slug]}
                        type="text"
                        label={gettext("Slug")}
                        placeholder={gettext("slug")}
                        class="font-mono text-sm"
                        phx-blur="field_change"
                      />
                      <.input
                        field={@form[:summary]}
                        type="text"
                        label={gettext("Summary")}
                        placeholder={gettext("One-line description")}
                        class="text-sm"
                      />
                    </div>
                    <.input
                      field={@form[:tags]}
                      type="text"
                      label={gettext("Tags")}
                      placeholder={gettext("comma, separated, tags")}
                      class="text-sm"
                    />
                    <.meta_fields page_type={@page_type} meta={@page.meta || %{}} />
                    <.markdown_editor
                      id="todo-editor"
                      body={@page.body}
                      context_id={@context_id}
                      save_status={@save_status}
                    />
                    <div class="flex justify-end gap-2 pt-2">
                      <button type="button" phx-click="cancel_edit" class="btn btn-ghost btn-sm">{gettext("Cancel")}</button>
                      <button type="submit" class="btn btn-primary btn-sm">{gettext("Save")}</button>
                    </div>
                  </div>
                </.form>
              <% end %>

              <div class="border-t border-base-300 pt-4">
                <h3 class="text-sm font-semibold text-base-content/60 mb-2">{gettext("Changelog")}</h3>
                <div class="space-y-1">
                  <div :for={version <- @versions} class="text-sm text-base-content/60">
                    {gettext("v%{version} — %{date} by %{author}",
                      version: version.version,
                      date: format_date(version.inserted_at),
                      author: version.changed_by || gettext("system")
                    )}
                  </div>
                  <p :if={@versions == []} class="text-sm text-base-content/40">
                    {gettext("No version history yet.")}
                  </p>
                </div>
              </div>
            </div>

            <div :if={@active_tab == "graph"}>
              <.page_graph id="todo-page-graph" nodes={@graph_nodes} edges={@graph_edges} />
            </div>
          </:tabs>
        </.page_detail>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".KanbanBoard">
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

  # ──────────────────────────────────────────────────────────────────────────
  # Lifecycle
  # ──────────────────────────────────────────────────────────────────────────

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
       tabs: @tabs,
       active_tab: "content",
       kanban_columns: @kanban_columns,
       priority_options: Enum.map(@priorities, fn {value, label, _class} -> {label, value} end),
       goal_options: [{gettext("No goal"), ""}],
       show_form: false,
       form: %{"title" => "", "priority" => "medium", "goal_slug" => "", "due_date" => ""},
       editing: false,
       save_status: "idle"
     )}
  end

  def handle_params(%{"slug" => slug} = params, _url, socket) do
    context = socket.assigns.context

    if context do
      case Brain.get_page_by_slug(slug, context.id) do
        nil ->
          {:noreply, push_navigate(socket, to: ~p"/todos")}

        page ->
          relations = Brain.list_relations_for_page(page.id)
          versions = Brain.list_page_versions(page.id)
          logs = Brain.list_log(context_id: context.id, limit: 10)
          %{nodes: graph_nodes, edges: graph_edges} = GraphHelpers.build_page_subgraph(page)
          editing = Map.get(params, "edit") == "true"
          edit_form = if editing, do: Brain.change_page(page) |> to_form(as: :page), else: nil

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
             active_tab: "content",
             graph_nodes: graph_nodes,
             graph_edges: graph_edges,
             editing: editing,
             form: edit_form,
             context_id: context.id,
             save_status: "idle",
             rendered_body: rendered_body
           )}
      end
    else
      {:noreply, push_navigate(socket, to: ~p"/todos")}
    end
  end

  def handle_params(_params, _url, socket) do
    if socket.assigns.context do
      items = Brain.list_todos(socket.assigns.context.id)
      goals = Brain.list_goals(socket.assigns.context.id)

      goal_options = [{gettext("No goal"), ""} | Enum.map(goals, &{&1.title, &1.slug})]

      {:noreply,
       assign(socket, items: items, goals: goals, goal_options: goal_options, page_title: gettext("Todos"))}
    else
      {:noreply,
       assign(socket, items: [], goals: [], goal_options: [{gettext("No goal"), ""}], page_title: gettext("Todos"))}
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Events
  # ──────────────────────────────────────────────────────────────────────────

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, switch_tab(socket, tab)}
  end

  def handle_event("node_click", %{"slug" => slug}, socket) do
    {:noreply, node_click(socket, slug)}
  end

  def handle_event("node_drag", %{"id" => id, "x" => x, "y" => y}, socket) do
    {:noreply, node_drag(socket, id, x, y)}
  end

  def handle_event("show_page", %{"slug" => slug}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/todos/#{slug}")}
  end

  def handle_event("new_todo", _params, socket) do
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

        meta =
          %{"kanban_status" => "backlog", "priority" => priority}
          |> maybe_put("goal_slug", goal_slug)
          |> maybe_put("due_date", due_date)

        attrs = %{
          "context_id" => context.id,
          "title" => title,
          "slug" => unique_slug(title, context.id),
          "page_type" => "todo",
          "meta" => meta
        }

        case Brain.create_page(attrs) do
          {:ok, _page} ->
            {:noreply,
             socket
             |> assign(items: Brain.list_todos(context.id), show_form: false)
             |> put_flash(:info, gettext("Todo created."))}

            {:error, _changeset} ->
              {:noreply, put_flash(socket, :error, gettext("Could not create todo."))}
        end
    end
  end

  def handle_event("move_todo", %{"slug" => slug, "target_status" => status}, socket) do
    case update_meta(socket, slug, &Map.put(&1, "kanban_status", status)) do
      {:ok, socket} ->
        {:noreply, assign(socket, items: Brain.list_todos(socket.assigns.context.id))}

      {:error, socket} ->
        {:noreply, socket}
    end
  end

  def handle_event("change_status", %{"slug" => slug, "status" => status}, socket) do
    case update_meta(socket, slug, &Map.put(&1, "kanban_status", status)) do
      {:ok, socket} ->
        {:noreply, socket}

      {:error, socket} ->
        {:noreply, socket}
    end
  end

  def handle_event("new_page", _params, socket) do
    {:noreply, push_navigate(socket, to: ~p"/todos/new")}
  end

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

  # ──────────────────────────────────────────────────────────────────────────
  # Helpers
  # ──────────────────────────────────────────────────────────────────────────

  defp update_meta(socket, slug, updater) do
    context = socket.assigns.context

    if context do
      case Brain.get_page_by_slug(slug, context.id) do
        nil ->
          {:error, put_flash(socket, :error, gettext("Todo not found."))}

        page ->
          # Be explicit: `|>` binds tighter than `||`, so apply the updater
          # after coalescing nil meta to an empty map.
          new_meta = updater.(page.meta || %{})

          case Brain.update_page(page, %{"meta" => new_meta}) do
            {:ok, updated} ->
              # On the show view we need the refreshed page; on index it's unused.
              {:ok, assign(socket, page: updated)}

            {:error, _changeset} ->
              {:error, put_flash(socket, :error, gettext("Could not update todo."))}
          end
      end
    else
      {:error, socket}
    end
  end

  defp maybe_put(meta, _key, ""), do: meta
  defp maybe_put(meta, key, value), do: Map.put(meta, key, value)

  defp unique_slug(title, context_id) do
    base = slugify(title)
    base = if base == "", do: "todo", else: base
    ensure_unique_slug(base, context_id, 0)
  end

  defp ensure_unique_slug(base, context_id, attempt) do
    slug =
      if attempt == 0 do
        base
      else
        suffix = :crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)
        "#{base}-#{suffix}"
      end

    if Brain.get_page_by_slug(slug, context_id) do
      ensure_unique_slug(base, context_id, attempt + 1)
    else
      slug
    end
  end

  defp slugify(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.replace(~r/^-+|-+$/, "")
  end

  # ── Meta accessors and formatting live in DranWeb.TodoHelpers ──
end
