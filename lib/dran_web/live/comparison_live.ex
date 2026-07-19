defmodule DranWeb.ComparisonLive do
  @moduledoc "LiveView for comparison pages: index list + detail view with inline editing."

  use DranWeb, :live_view

  alias Dran.Brain
  alias DranWeb.GraphHelpers
  alias DranWeb.PageEdit
  alias DranWeb.Plugs.Auth

  @page_type "comparison"
  @tabs [{"content", gettext("Content")}]

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
            <.link navigate={~p"/comparisons"} class="btn btn-primary btn-sm"><.icon
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
            <.page_graph id="comparison-page-graph" nodes={@graph_nodes} edges={@graph_edges} />
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
                  editor_id="comparison-editor"
                />
              <% else %>
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
            </div>          </:tabs>
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
       active_nav: "comparisons"
     )}
  end

  def handle_params(%{"slug" => slug} = params, _url, socket) do
    context = socket.assigns.context

    if context do
      case Brain.get_page_by_slug(slug, context.id) do
        nil ->
          {:noreply, push_navigate(socket, to: ~p"/comparisons")}

        page ->
          relations = Brain.list_relations_for_page(page.id)
          versions = Brain.list_page_versions(page.id)
          logs = Brain.list_log(context_id: context.id, limit: 10)
          %{nodes: graph_nodes, edges: graph_edges} = GraphHelpers.build_page_subgraph(page)
          editing = Map.get(params, "edit") == "true"
          form = if editing, do: Brain.change_page(page) |> to_form(as: :page), else: nil

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
             form: form,
             context_id: context.id,
             save_status: "idle",
             rendered_body: rendered_body
           )}
      end
    else
      {:noreply, push_navigate(socket, to: ~p"/comparisons")}
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
       page_title: gettext("Comparisons")
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
    do: {:noreply, push_navigate(socket, to: ~p"/comparisons/#{slug}")}

  def handle_event("new_page", _params, socket),
    do: {:noreply, push_navigate(socket, to: ~p"/comparisons/new")}

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
end
