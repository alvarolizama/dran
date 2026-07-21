defmodule DranWeb.PlanLive do
  @moduledoc "LiveView for plan pages: index list + detail view with inline editing."

  use DranWeb, :live_view

  alias Dran.Brain
  alias DranWeb.GraphHelpers
  alias DranWeb.PageEdit
  alias DranWeb.PageTypes
  alias DranWeb.Plugs.Auth

  @page_type "plan"
  @tabs [
    {"content", gettext("Content")},
    {"todos", gettext("Todos")}
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
            <.link navigate={~p"/plans"} class="btn btn-primary btn-sm"><.icon
              name="hero-arrow-left"
              class="size-4"
            /> {gettext("Back")}</.link>
            <button :if={not @editing} phx-click="toggle_edit" class="btn btn-primary btn-sm"><.icon
              name="hero-pencil"
              class="size-4"
            /> {gettext("Edit")}</button>
            <button :if={@editing} phx-click="save_page" class="btn btn-success btn-sm"><.icon
              name="hero-check"
              class="size-4"
            /> {gettext("Save")}</button>
            <button :if={@editing} phx-click="cancel_edit" class="btn btn-ghost btn-sm"><.icon
              name="hero-x-mark"
              class="size-4"
            /> {gettext("Cancel")}</button>
          </:actions>
          <:graph>
            <.page_graph id="plan-page-graph" nodes={@graph_nodes} edges={@graph_edges} />
          </:graph>

          <:tabs>
            <.tabs_bar tabs={@tabs} active_tab={@active_tab} />
            <div :if={@active_tab == "content"} class="space-y-6">
              <%= if @editing do %>
                <.page_edit_form
                  form={@form}
                  page={@page}
                  page_type={@page_type}
                  context_id={@context_id}
                  save_status={@save_status}
                  editor_id="plan-editor"
                />
              <% else %>
                <%!-- Status + horizon + period + due_date panel (§7.4) --%>
                <div class="flex items-center gap-3 mb-4 text-sm">
                  <span class={"px-2 py-0.5 rounded " <> plan_status_class(@page)}>
                    {String.capitalize(meta_get(@page.meta, "status") || "draft")}
                  </span>
                  <span class="text-base-content/60">
                    {String.capitalize(meta_get(@page.meta, "horizon") || "")}
                    <span :if={meta_get(@page.meta, "period")}>· {meta_get(@page.meta, "period")}</span>
                  </span>
                  <span :if={meta_get(@page.meta, "due_date")} class="text-base-content/60">
                    {gettext("Due")}: {meta_get(@page.meta, "due_date")}
                  </span>
                </div>
                <div class="prose prose-base dark:prose-invert max-w-none">
                  {@rendered_body}
                </div>
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
              <% end %>
            </div>
            <%!-- Todos: lista simple con link a kanban global (§7.3) --%>
            <div :if={@active_tab == "todos"}>
              <div class="flex items-center justify-between mb-3">
                <span class="text-sm text-base-content/60">{length(@plan_todos)} {gettext(
                  "todos linked"
                )}</span>
                <.link navigate={~p"/kanban?plan=#{@page.slug}"} class="btn btn-ghost btn-xs">
                  {gettext("Open in Kanban")} →
                </.link>
              </div>
              <div :for={todo <- @plan_todos} class="p-3 rounded-lg border border-base-300 mb-2">
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
                <div :if={todo.summary} class="text-xs text-base-content/60 mt-1">{todo.summary}</div>
              </div>
              <p :if={@plan_todos == []} class="text-sm text-base-content/40">
                {gettext("No todos linked to this plan.")}
              </p>
            </div>
          </:tabs>
        </.page_detail>
      </div><div :if={@live_action != :show}>
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
      if context,
        do:
          allow_upload(socket, :file,
            accept:
              ~w(image/* video/* audio/* application/pdf text/plain text/markdown text/csv text/html application/json application/zip),
            max_file_size: Dran.Uploads.max_size(),
            auto_upload: true,
            progress: &handle_progress/3
          ),
        else: socket

    {:ok,
     assign(socket,
       context: context,
       page_type: @page_type,
       tabs: @tabs,
       active_tab: "content",
       editing: false,
       save_status: "idle",
       active_nav: "plans"
     )}
  end

  def handle_params(%{"slug" => slug} = params, _url, socket) do
    context = socket.assigns.context

    if context do
      case Brain.get_page_by_slug(slug, context.id) do
        nil ->
          {:noreply, push_navigate(socket, to: ~p"/plans")}

        page ->
          relations = Brain.list_relations_for_page(page.id)
          versions = Brain.list_page_versions(page.id)
          logs = Brain.list_log(context_id: context.id, limit: 10)
          %{nodes: graph_nodes, edges: graph_edges} = GraphHelpers.build_page_subgraph(page)
          editing = Map.get(params, "edit") == "true"
          form = if editing, do: Brain.change_page(page) |> to_form(as: :page), else: nil

          # §7.2 — load todos linked to this plan via meta.plan_slug.
          # Brain.list_pages already supports a :plan_slug filter (Phase 2),
          # so we use it directly here instead of filtering in memory.
          plan_todos =
            Brain.list_pages(
              context_id: context.id,
              type: "todo",
              plan_slug: page.slug,
              include_body: false,
              limit: 500
            )

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
             plan_todos: plan_todos,
             graph_nodes: graph_nodes,
             graph_edges: graph_edges,
             editing: editing,
             form: form,
             context_id: context.id,
             save_status: "idle",
             rendered_body: rendered_body
           )}
      end
    else
      {:noreply, push_navigate(socket, to: ~p"/plans")}
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
       page_title: gettext("Plans")
     )}
  end

  def handle_event("filter_archived", %{"type" => type}, socket) do
    {:noreply, assign(socket, archived_filter: type)}
  end

  def handle_event("switch_tab", %{"tab" => tab}, socket), do: {:noreply, switch_tab(socket, tab)}

  def handle_event("node_click", %{"slug" => slug}, socket),
    do: {:noreply, node_click(socket, slug)}

  def handle_event("node_drag", %{"id" => id, "x" => x, "y" => y}, socket),
    do: {:noreply, node_drag(socket, id, x, y)}

  def handle_event("show_page", %{"slug" => slug}, socket),
    do: {:noreply, push_navigate(socket, to: ~p"/plans/#{slug}")}

  def handle_event("new_page", _params, socket),
    do: {:noreply, push_navigate(socket, to: ~p"/plans/new")}

  def handle_event("delete_page", p, s), do: PageEdit.handle_event("delete_page", p, s)
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
  defp meta_get(meta, key) when is_map(meta), do: Map.get(meta, key)
  defp meta_get(nil, _key), do: nil

  # §7.4 — Tailwind class for the plan status badge.
  defp plan_status_class(page) do
    case meta_get(page.meta, "status") do
      "active" -> "bg-green-100 text-green-700"
      "done" -> "bg-blue-100 text-blue-700"
      "archived" -> "bg-base-300 text-base-content/60"
      _ -> "bg-amber-100 text-amber-700"
    end
  end

  # ── Kanban status helpers (for the simple Todos list) ──

  defp kanban_status(page) do
    case meta_get(page.meta, "kanban_status") do
      s when is_binary(s) and s != "" -> s
      _ -> "backlog"
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
end
