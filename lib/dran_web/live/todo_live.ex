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
  @tabs [{"graph", gettext("Graph")}, {"content", gettext("Content")}]

  @kanban_columns [
    {"backlog", gettext("Backlog"), "bg-base-300"},
    {"this_week", gettext("This Week"), "bg-blue-500/20 text-blue-700"},
    {"today", gettext("Today"), "bg-amber-500/20 text-amber-700"},
    {"in_progress", gettext("In Progress"), "bg-purple-500/20 text-purple-700"},
    {"done", gettext("Done"), "bg-green-500/20 text-green-700"},
    {"cancelled", gettext("Cancelled"), "bg-red-500/20 text-red-700"}
  ]

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
      context_slug={@context_slug}
      contexts={@contexts}
    >
      <div
        :if={@live_action == :index}
        id="todo-list"
        data-testid="todo-list"
        class="p-6"
      >
        <div class="flex items-center justify-between mb-4">
          <div>
            <h1 class="text-title">{gettext("Todos")}</h1>
            <p class="text-caption mt-0.5">
              {gettext("%{count} items", count: length(@items))}
            </p>
          </div>
          <div class="flex items-center gap-2">
            <.link navigate={~p"/kanban"} class="btn btn-ghost btn-sm">
              <.icon name="hero-view-columns" class="w-4 h-4" /> {gettext("Board")}
            </.link>
            <.link navigate={~p"/todos/new"} class="btn btn-primary btn-sm">
              <.icon name="hero-plus" class="w-4 h-4" /> {gettext("New Todo")}
            </.link>
          </div>
        </div>

        <form phx-submit="quick_add_todo" class="mb-4 flex flex-wrap items-end gap-3">
          <div class="flex-1 min-w-56">
            <input
              type="text"
              name="title"
              required
              placeholder={gettext("What needs to be done?")}
              class="w-full px-3 py-2 text-sm rounded-lg border border-base-300 bg-base-100 transition-colors duration-150 focus:outline-none focus:ring-1 focus:ring-primary"
            />
          </div>
          <div>
            <select
              name="goal_slug"
              aria-label={gettext("Goal")}
              class="px-3 py-2 text-sm rounded-lg border border-base-300 bg-base-100 transition-colors duration-150 focus:outline-none focus:ring-1 focus:ring-primary"
            >
              <option value="">{gettext("Sin objetivo")}</option>
              <option :for={g <- @goals} value={g.slug}>{g.title}</option>
            </select>
          </div>
          <button type="submit" class="btn btn-primary btn-sm">
            <.icon name="hero-plus" class="w-4 h-4" /> {gettext("Agregar")}
          </button>
        </form>

        <div :if={@items == []} class="surface-2 p-12 text-center">
          <.icon name="hero-check-circle" class="size-7 mx-auto text-base-content/30" />
          <p class="text-caption mt-3">{gettext("No todos yet.")}</p>
        </div>

        <div :if={@items != []} class="space-y-2">
          <div
            :for={item <- @items}
            data-testid={"todo-row-" <> item.slug}
            class="surface-2 lift p-3 flex flex-wrap items-center gap-3 cursor-pointer"
            phx-click="show_page"
            phx-value-slug={item.slug}
          >
            <div class="flex-1 min-w-48">
              <div class="font-medium text-sm leading-snug break-words">{item.title}</div>
              <div :if={item.tags != []} class="flex flex-wrap gap-1 mt-1">
                <span
                  :for={tag <- Enum.take(item.tags, 4)}
                  class="px-1.5 py-0.5 text-[11px] rounded bg-base-200 text-base-content/60"
                >
                  #{tag}
                </span>
              </div>
            </div>
            <span class={"text-[11px] font-medium px-1.5 py-0.5 rounded shrink-0 " <> priority_badge_class(item)}>
              {priority_label(item)}
            </span>
            <span
              :if={due_date(item)}
              class={"shrink-0 " <> due_date_display_class(overdue?(item))}
            >
              <.icon name="hero-calendar" class="size-3.5" /> {format_due(due_date(item))}
            </span>
            <div class="flex items-center gap-1 shrink-0">
              <button
                :for={{status, label, badge_class} <- @kanban_columns}
                phx-click="change_status"
                phx-value-slug={item.slug}
                phx-value-status={status}
                title={label}
                class={status_button_class(kanban_status(item), status, badge_class)}
              >
                {label}
              </button>
            </div>
          </div>
        </div>

        <div :if={@archived_items != []} class="mt-4">
          <button
            phx-click="toggle_archived"
            class="flex items-center gap-1.5 text-xs font-medium text-base-content/50 hover:text-base-content transition-colors"
          >
            <.icon
              name="hero-chevron-right"
              class={"size-3 transition-transform duration-150 " <> if(@show_archived, do: "rotate-90", else: "")}
            />
            <.icon name="hero-archive-box" class="size-3.5" />
            {gettext("Archived")} ({length(@archived_items)})
          </button>
          <div :if={@show_archived} class="mt-2 flex flex-wrap gap-2">
            <div
              :for={item <- @archived_items}
              phx-click="show_page"
              phx-value-slug={item.slug}
              data-testid={"archived-todo-" <> item.slug}
              class="px-3 py-1.5 rounded-lg border border-base-300 text-xs text-base-content/60 cursor-pointer hover:border-primary/40 hover:text-base-content transition-colors opacity-70 hover:opacity-100"
            >
              {item.title}
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
                <span class="text-caption mr-1">{gettext("Status:")}</span>
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
                <.page_edit_form
                  form={@form}
                  page={@page}
                  page_type={@page_type}
                  context_id={@context_id}
                  save_status={@save_status}
                  editor_id="todo-editor"
                />
              <% end %>

              <div class="border-t border-base-300 pt-4">
                <h3 class="text-sm font-semibold text-base-content/60 mb-2">
                  {gettext("Changelog")}
                </h3>
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
    </Layouts.app>
    """
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Lifecycle
  # ──────────────────────────────────────────────────────────────────────────

  @impl true
  def mount(_params, session, socket) do
    {socket, context} = Auth.assign_to_socket(socket, session)

    socket =
      if context do
        if connected?(socket) do
          Phoenix.PubSub.subscribe(Dran.PubSub, "brain:#{context.id}")
        end

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
       active_tab: "graph",
       kanban_columns: @kanban_columns,
       editing: false,
       save_status: "idle",
       active_nav: "todos"
     )}
  end

  @impl true
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
             active_tab: "graph",
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
      archived_items = Brain.list_todos(context_id: socket.assigns.context.id, archived: true)

      {:noreply,
       assign(socket,
         items: items,
         archived_items: archived_items,
         show_archived: false,
         goals: Brain.list_goals(socket.assigns.context.id),
         page_title: gettext("Todos")
       )}
    else
      {:noreply,
       assign(socket,
         items: [],
         archived_items: [],
         show_archived: false,
         goals: [],
         page_title: gettext("Todos")
       )}
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Events
  # ──────────────────────────────────────────────────────────────────────────

  @impl true
  def handle_info({:page_changed, _action, _page}, socket) do
    # A page changed (agent, MCP, another tab) — reload the list if we're on
    # the index so moved/created/archived todos appear in real time.
    if socket.assigns.live_action == :index and socket.assigns.context do
      {:noreply,
       assign(socket,
         items: Brain.list_todos(socket.assigns.context.id),
         archived_items: Brain.list_todos(context_id: socket.assigns.context.id, archived: true)
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, switch_tab(socket, tab)}
  end

  def handle_event("node_click", %{"slug" => slug}, socket) do
    {:noreply, node_click(socket, slug)}
  end

  def handle_event("node_drag", %{"id" => id, "x" => x, "y" => y}, socket) do
    {:noreply, node_drag(socket, id, x, y)}
  end

  def handle_event("toggle_archived", _params, socket) do
    {:noreply, assign(socket, show_archived: not socket.assigns.show_archived)}
  end

  def handle_event("show_page", %{"slug" => slug}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/todos/#{slug}")}
  end

  def handle_event("quick_add_todo", params, socket) do
    context = socket.assigns.context
    title = String.trim(params["title"] || "")

    cond do
      context == nil ->
        {:noreply, put_flash(socket, :error, gettext("No context available."))}

      title == "" ->
        {:noreply, put_flash(socket, :error, gettext("Title is required."))}

      true ->
        meta = %{"kanban_status" => "backlog", "priority" => "medium"}
        meta = case params["goal_slug"] do
          nil -> meta
          "" -> meta
          goal -> Map.put(meta, "goal_slug", goal)
        end

        attrs = %{
          "context_id" => context.id,
          "title" => title,
          "slug" => Dran.Slug.generate(title, context.id, "todo"),
          "page_type" => "todo",
          "meta" => meta
        }

        case Brain.create_page(attrs) do
          {:ok, _page} ->
            {:noreply,
             socket
             |> assign(items: Brain.list_todos(context.id))
             |> put_flash(:info, gettext("Todo created."))}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, gettext("Could not create todo."))}
        end
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

  # ── Local display helpers (design-system colors) ──
  # These shadow the imported TodoHelpers versions to use semantic
  # color tokens (error/warning/info) instead of raw Tailwind palettes.

  defp priority_badge_class(page) do
    case priority(page) do
      "urgent" -> "bg-error/15 text-error"
      "high" -> "bg-warning/15 text-warning"
      "medium" -> "bg-info/15 text-info"
      "low" -> "bg-base-300 text-base-content/60"
      _ -> "bg-base-300 text-base-content/60"
    end
  end

  defp due_date_display_class(true),
    do: "flex items-center gap-1 mt-1.5 text-xs font-medium text-error"

  defp due_date_display_class(false),
    do: "flex items-center gap-1 mt-1.5 text-caption"

  # ── Meta accessors and formatting live in DranWeb.TodoHelpers ──
end
