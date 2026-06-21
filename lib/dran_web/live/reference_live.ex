defmodule DranWeb.ReferenceLive do
  @moduledoc "LiveView for reference pages: index list + detail view with inline editing."

  use DranWeb, :live_view

  alias Dran.Brain
  alias DranWeb.GraphHelpers
  alias DranWeb.PageEdit
  alias DranWeb.Plugs.Auth

  @page_type "reference"
  @tabs [{"content", "Content"}, {"graph", "Graph"}]

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_user={@current_user}
      context_slug={@context_slug}
      contexts={@contexts}
    >
      <div :if={@live_action == :show}>
        <.page_detail
          page={@page}
          relations={@relations}
          versions={@versions}
          logs={@logs}
          context_slug={@context_slug}
          backlinks={@backlinks}
        >
          <:actions>
            <.link navigate={~p"/references"} class="btn btn-primary btn-sm"><.icon
              name="hero-arrow-left"
              class="size-4"
            /> Back</.link>
            <button :if={not @editing} phx-click="toggle_edit" class="btn btn-primary btn-sm"><.icon
              name="hero-pencil"
              class="size-4"
            /> Edit</button>
            <button :if={@editing} phx-click="save_page" class="btn btn-success btn-sm"><.icon
              name="hero-check"
              class="size-4"
            /> Save</button>
            <button :if={@editing} phx-click="cancel_edit" class="btn btn-ghost btn-sm"><.icon
              name="hero-x-mark"
              class="size-4"
            /> Cancel</button>
          </:actions>
          <:tabs>
            <.tabs_bar tabs={@tabs} active_tab={@active_tab} />
            <div :if={@active_tab == "content"} class="space-y-6">
              <%= if @editing do %>
                <.form
                  for={@form}
                  id="page-edit-form"
                  phx-change="validate_page"
                  phx-submit="save_page"
                >
                  <div class="space-y-5">
                    <.input
                      field={@form[:title]}
                      type="text"
                      label="Title"
                      placeholder="Enter a title…"
                      class="text-lg font-medium"
                    />
                    <div class="grid grid-cols-2 gap-4">
                      <.input
                        field={@form[:slug]}
                        type="text"
                        placeholder="slug"
                        class="w-full"
                        phx-blur="field_change"
                      />
                      <.input
                        field={@form[:summary]}
                        type="text"
                        placeholder="Summary (optional)"
                        class="w-full"
                      />
                    </div>
                    <.input
                      field={@form[:tags]}
                      type="text"
                      placeholder="Tags (comma separated)"
                      class="w-full"
                    />
                    <.markdown_editor
                      id="reference-editor"
                      body={@page.body}
                      context_id={@context_id}
                      save_status={@save_status}
                    />
                    <div class="flex justify-end gap-2 pt-2">
                      <button type="button" phx-click="cancel_edit" class="btn btn-ghost btn-sm">Cancel</button>
                      <button type="submit" class="btn btn-primary btn-sm">Save</button>
                    </div>
                  </div>
                </.form>
              <% else %>
                <div class="prose prose-base dark:prose-invert max-w-none">
                  {render_markdown(@page.body, context_id: @page.context_id)}
                </div>
                <div class="border-t border-base-300 pt-4">
                  <h3 class="text-sm font-semibold text-base-content/60 mb-2">Changelog</h3>
                  <div class="space-y-1">
                    <div :for={version <- @versions} class="text-sm text-base-content/60">
                      v{version.version} — {format_date(version.inserted_at)} by {version.changed_by ||
                        "system"}
                    </div>
                    <p :if={@versions == []} class="text-sm text-base-content/40">
                      No version history yet.
                    </p>
                  </div>
                </div>
              <% end %>
            </div>
            <div :if={@active_tab == "graph"}>
              <.page_graph id="reference-page-graph" nodes={@graph_nodes} edges={@graph_edges} />
            </div>
          </:tabs>
        </.page_detail>
      </div><div :if={@live_action != :show}>
        <.page_list pages={@pages} page_type={@page_type} context_slug={@context_slug} />
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
       save_status: "idle"
     )}
  end

  def handle_params(%{"slug" => slug} = params, _url, socket) do
    context = socket.assigns.context

    if context do
      case Brain.get_page_by_slug(slug, context.id) do
        nil ->
          {:noreply, push_navigate(socket, to: ~p"/references")}

        page ->
          relations = Brain.list_relations_for_page(page.id)
          versions = Brain.list_page_versions(page.id)
          logs = Brain.list_log(context_id: context.id, limit: 10)
          backlinks = Brain.find_backlinks(page.slug, context.id)
          %{nodes: graph_nodes, edges: graph_edges} = GraphHelpers.build_page_subgraph(page)
          editing = Map.get(params, "edit") == "true"
          form = if editing, do: Brain.change_page(page) |> to_form(as: :page), else: nil

          {:noreply,
           assign(socket,
             page: page,
             relations: relations,
             versions: versions,
             logs: logs,
             backlinks: backlinks,
             page_title: page.title,
             active_tab: "content",
             graph_nodes: graph_nodes,
             graph_edges: graph_edges,
             editing: editing,
             form: form,
             context_id: context.id,
             save_status: "idle"
           )}
      end
    else
      {:noreply, push_navigate(socket, to: ~p"/references")}
    end
  end

  def handle_params(_params, _url, socket) do
    pages =
      if socket.assigns.context,
        do: Brain.list_pages(context_id: socket.assigns.context.id, type: @page_type),
        else: []

    {:noreply, assign(socket, pages: pages, page_title: "References")}
  end

  def handle_event("switch_tab", %{"tab" => tab}, socket), do: {:noreply, switch_tab(socket, tab)}

  def handle_event("node_click", %{"slug" => slug}, socket),
    do: {:noreply, node_click(socket, slug)}

  def handle_event("node_drag", %{"id" => id, "x" => x, "y" => y}, socket),
    do: {:noreply, node_drag(socket, id, x, y)}

  def handle_event("show_page", %{"slug" => slug}, socket),
    do: {:noreply, push_navigate(socket, to: ~p"/references/#{slug}")}

  def handle_event("new_page", _params, socket),
    do: {:noreply, push_navigate(socket, to: ~p"/references/new")}

  def handle_event("toggle_edit", p, s), do: PageEdit.handle_event("toggle_edit", p, s)
  def handle_event("cancel_edit", p, s), do: PageEdit.handle_event("cancel_edit", p, s)
  def handle_event("validate_page", p, s), do: PageEdit.handle_event("validate_page", p, s)
  def handle_event("save_page", p, s), do: PageEdit.handle_event("save_page", p, s)
  def handle_event("body_change", p, s), do: PageEdit.handle_event("body_change", p, s)
  def handle_event("field_change", p, s), do: PageEdit.handle_event("field_change", p, s)
  def handle_event("request_upload", p, s), do: PageEdit.handle_event("request_upload", p, s)
  def handle_event("upload_complete", p, s), do: PageEdit.handle_event("upload_complete", p, s)
  defp handle_progress(:file, _entry, socket), do: {:noreply, socket}
end
