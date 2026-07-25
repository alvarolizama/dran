defmodule DranWeb.PlanLive do
  @moduledoc "LiveView for plan pages: index list + detail view with inline editing."

  use DranWeb, :live_view

  alias Dran.Brain
  alias DranWeb.GraphHelpers
  alias DranWeb.PageEdit
  alias DranWeb.PageTypes
  alias DranWeb.Plugs.Auth

  @page_type "plan"

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
          content_hidden={@active_tab not in ["content", "graph"]}
          graph_active={@active_tab == "graph"}
          content_tab_value="content"
          editing={@editing}
        >
          <:actions>
            <.link navigate={~p"/plans"} class="btn btn-primary btn-sm"><.icon
              name="hero-arrow-left"
              class="size-4"
            /> {gettext("Back")}</.link>
          </:actions>
          <:attributes>
            <.page_attributes
              form={@form}
              page={@page}
              page_type={@page_type}
              context_id={@context_id}
              editor_id="plan-editor"
            />
          </:attributes>
          <:graph>
            <.page_graph id="plan-page-graph" nodes={@graph_nodes} edges={@graph_edges} />
          </:graph>

          <:tabs>
            <.page_edit_form
              form={@form}
              page={@page}
              page_type={@page_type}
              context_id={@context_id}
              save_status={@save_status}
              editor_id="plan-editor"
            />
          </:tabs>

          <:extra_tabs>
            <button
              phx-click="switch_tab"
              phx-value-tab="todos"
              class={[
                "px-3 py-2 text-sm font-medium border-b-2 -mb-px transition-colors duration-150",
                @active_tab == "todos" && "border-primary text-primary",
                @active_tab != "todos" &&
                  "border-transparent text-base-content/60 hover:text-base-content hover:border-base-content/20"
              ]}
            >
              {gettext("Todos")}
            </button>
          </:extra_tabs>

          <:extra_content>
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
          </:extra_content>
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
       active_tab: "content",
       editing: true,
       save_status: "idle",
       active_nav: "plans"
     )}
  end

  def handle_params(%{"slug" => slug} = _params, _url, socket) do
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
          form = Brain.change_page(page) |> to_form(as: :page)

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
             editing: true,
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
