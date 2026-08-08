defmodule DranWeb.TodoLive do
  @moduledoc """
  LiveView for todo pages.

  Index renders a Kanban board with HTML5 drag & drop between six status
  columns. Show renders the shared `page_detail` component plus a row of
  status buttons for quick kanban_status changes.
  """

  use DranWeb, :live_view
  on_mount {DranWeb.DisabledTypes, "todo"}

  alias Dran.Brain
  alias DranWeb.PageDetail
  alias DranWeb.PageEdit
  alias DranWeb.PageTypes
  import DranWeb.TodoHelpers

  @page_type "todo"
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
            <.link
              :if={Brain.page_type_enabled?(@context, "todo")}
              navigate={~p"/kanban"}
              class="btn btn-ghost btn-sm"
            >
              <.icon name="hero-view-columns" class="w-4 h-4" /> {gettext("Board")}
            </.link>
            <button
              :if={@archived_items != []}
              type="button"
              phx-click="toggle_archived"
              class={[
                "btn btn-ghost btn-sm",
                @show_archived && "btn-active border-primary/40"
              ]}
              data-testid="toggle-archived"
            >
              <.icon
                name={if @show_archived, do: "hero-check-circle", else: "hero-archive-box"}
                class="w-4 h-4"
              />
              {if @show_archived, do: gettext("Todos"), else: gettext("Archived")} ({if @show_archived,
                do: length(@items),
                else: length(@archived_items)})
            </button>
            <.link navigate={~p"/todos/new"} class="btn btn-primary btn-sm">
              <.icon name="hero-plus" class="w-4 h-4" /> {gettext("New Todo")}
            </.link>
          </div>
        </div>

        <div :if={!@show_archived}>
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

              <%!-- Archive button — bottom-right corner of the row, same as /plans --%>
              <button
                type="button"
                phx-click="archive_todo"
                phx-value-slug={item.slug}
                phx-click-stop-propagation
                title={gettext("Archive")}
                class="p-1 rounded-lg text-base-content/40 hover:text-error hover:bg-error/10 transition-colors shrink-0"
                data-testid={"archive-btn-" <> item.slug}
              >
                <.icon name="hero-archive-box" class="size-4" />
              </button>
            </div>
          </div>
        </div>

        <div :if={@show_archived} class="rounded-xl border border-base-300 bg-base-200/30">
          <div class="flex items-center justify-between px-4 py-3 border-b border-base-300">
            <div class="flex items-center gap-2 text-sm font-semibold text-base-content/60">
              <.icon name="hero-archive-box" class="size-4" />
              {gettext("Archived")}
              <span class="px-1.5 py-0.5 text-xs rounded-md bg-base-300 text-base-content/60">
                {length(@archived_items)}
              </span>
            </div>
          </div>
          <div class="px-4 py-2 space-y-1">
            <div
              :for={item <- @archived_items}
              class="flex items-center gap-3 px-3 py-2 rounded-lg hover:bg-base-200 transition-colors opacity-70 hover:opacity-100"
              data-testid={"archived-todo-" <> item.slug}
            >
              <.icon name="hero-check-circle" class="size-4 text-base-content/40 shrink-0" />
              <.link
                navigate={~p"/todos/#{item.slug}"}
                class="text-sm flex-1 truncate hover:text-primary transition-colors"
              >
                {item.title}
              </.link>
              <span class="text-[11px] font-medium px-2 py-0.5 rounded-full bg-base-300 text-base-content/50">
                {gettext("Todo")}
              </span>
              <span :if={item.updated_at} class="text-caption shrink-0">
                {Calendar.strftime(item.updated_at, "%b %d")}
              </span>
              <button
                type="button"
                phx-click="unarchive_page"
                phx-value-slug={item.slug}
                title={gettext("Unarchive")}
                class="p-1 rounded-lg text-base-content/40 hover:text-success hover:bg-success/10 transition-colors"
                data-testid={"unarchive-btn-" <> item.slug}
              >
                <.icon name="hero-arrow-up-on-square" class="size-4" />
              </button>
            </div>
            <p
              :if={@archived_items == []}
              class="text-xs text-base-content/30 text-center py-2"
            >
              {gettext("No archived todos")}
            </p>
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
          editing={@editing}
          content_tab_value="content"
          content_hidden={@active_tab != "content"}
          active_tab={@active_tab}
        >
          <:actions>
            <.link navigate={~p"/todos"} class="btn btn-primary btn-sm">
              <.icon name="hero-arrow-left" class="size-4" /> {gettext("Back")}
            </.link>
            <.link navigate={~p"/graph/#{@page.slug}"} class="btn btn-ghost btn-sm">
              <.icon name="hero-share" class="size-4" /> {gettext("Graph")}
            </.link>
            <.link :if={@editing} patch={PageTypes.page_show_path(@page)} class="btn btn-ghost btn-sm">
              <.icon name="hero-eye" class="size-4" /> {gettext("View")}
            </.link>
            <.link
              :if={not @editing}
              patch={PageTypes.page_show_path(@page) <> "?edit=true"}
              class="btn btn-ghost btn-sm"
            >
              <.icon name="hero-pencil" class="size-4" /> {gettext("Edit")}
            </.link>
          </:actions>

          <:attributes>
            <.page_attributes
              form={@form}
              page={@page}
              page_type={@page_type}
              context_id={@context_id}
              editor_id="todo-editor"
            />
          </:attributes>

          <:insights>
            <div class="space-y-4">
              <div :if={@community_summary} class="surface-2 rounded-lg p-4">
                <h3 class="text-sm font-semibold mb-2">{gettext("Community Context")}</h3>
                <p class="text-sm text-base-content/70">{@community_summary.summary}</p>
                <p class="text-xs text-base-content/40 mt-1">
                  {gettext("Community")} #{@community_summary.community_id} · {@community_summary.page_count} {gettext(
                    "pages"
                  )}
                </p>
              </div>
              <div
                :if={!@community_summary}
                class="text-sm text-base-content/40 text-center py-8"
              >
                {gettext("No community data yet. Run community summaries first.")}
              </div>
            </div>
          </:insights>

          <:tabs :if={@editing}>
            <div :if={meta_get(@page.meta, "kind")} class="flex items-center gap-2">
              <span class="px-2 py-0.5 rounded bg-primary/15 text-primary text-xs font-medium">
                {String.capitalize(meta_get(@page.meta, "kind"))}
              </span>
            </div>
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

            <.page_edit_form
              form={@form}
              page={@page}
              page_type={@page_type}
              context_id={@context_id}
              save_status={@save_status}
              editor_id="todo-editor"
            />
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
    PageDetail.mount_page_viewer(socket, session,
      page_type: @page_type,
      active_nav: "todos",
      extra_assigns: [
        kanban_columns: @kanban_columns
      ]
    )
  end

  @impl true
  def handle_params(%{"slug" => slug} = params, _url, socket) do
    PageDetail.load_page_detail(socket, params, slug, redirect_to: "/todos")
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
  def handle_info({:page_changed, _action, changed_page}, socket) do
    cond do
      # Index: reload the list so moved/created/archived todos appear in real time
      socket.assigns.live_action == :index and socket.assigns.context ->
        {:noreply,
         assign(socket,
           items: Brain.list_todos(socket.assigns.context.id),
           archived_items: Brain.list_todos(context_id: socket.assigns.context.id, archived: true)
         )}

      # Show: if the page we're viewing changed, reload it
      socket.assigns[:page] && socket.assigns.page.id == changed_page.id ->
        page = Brain.get_page(changed_page.id)

        if page do
          rendered_body =
            render_markdown(page.body,
              context_id: page.context_id,
              inline_links: Map.get(page.meta || %{}, "inline_links", [])
            )

          form = Brain.change_page(page) |> to_form(as: :page)
          {:noreply, assign(socket, page: page, rendered_body: rendered_body, form: form)}
        else
          {:noreply, socket}
        end

      true ->
        {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, switch_tab(socket, tab)}
  end

  def handle_event("toggle_archived", _params, socket) do
    {:noreply, assign(socket, show_archived: not socket.assigns.show_archived)}
  end

  def handle_event("show_page", %{"slug" => slug}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/todos/#{slug}")}
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
              {:noreply,
               socket
               |> assign(
                 items: Brain.list_todos(context.id),
                 archived_items: Brain.list_todos(context_id: context.id, archived: true)
               )
               |> put_flash(:info, gettext("Todo archived."))}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, gettext("Could not archive todo."))}
          end
      end
    else
      {:noreply, socket}
    end
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

        meta =
          case params["goal_slug"] do
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

  defp meta_get(meta, key) when is_map(meta), do: Map.get(meta, key)
  defp meta_get(nil, _key), do: nil

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
