defmodule DranWeb.NoteLive do
  @moduledoc "LiveView for note pages: index list + detail view with inline editing."

  use DranWeb, :live_view

  alias Dran.Brain
  alias DranWeb.GraphHelpers
  alias DranWeb.PageEdit
  alias DranWeb.Plugs.Auth

  @page_type "note"
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
        >
          <:actions>
            <.link navigate={~p"/notes"} class="btn btn-primary btn-sm">
              <.icon name="hero-arrow-left" class="size-4" /> Back
            </.link>

            <button
              :if={not @editing}
              phx-click="toggle_edit"
              class="btn btn-primary btn-sm"
            >
              <.icon name="hero-pencil" class="size-4" /> Edit
            </button>

            <button
              :if={@editing}
              phx-click="save_page"
              class="btn btn-success btn-sm"
            >
              <.icon name="hero-check" class="size-4" /> Save
            </button>

            <button
              :if={@editing}
              phx-click="cancel_edit"
              class="btn btn-ghost btn-sm"
            >
              <.icon name="hero-x-mark" class="size-4" /> Cancel
            </button>
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
                        label="Slug"
                        placeholder="slug"
                        class="font-mono text-sm"
                      />
                      <.input
                        field={@form[:summary]}
                        type="text"
                        label="Summary"
                        placeholder="One-line description"
                        class="text-sm"
                      />
                    </div>

                    <.input
                      field={@form[:tags]}
                      type="text"
                      label="Tags"
                      placeholder="comma, separated, tags"
                      class="text-sm"
                    />

                    <.meta_fields page_type={@page_type} meta={@page.meta || %{}} />

                    <div>
                      <span class="label mb-1 block text-sm font-medium text-base-content/70">Content</span>
                      <.markdown_editor
                        id="note-editor"
                        body={@page.body}
                        context_id={@context_id}
                        save_status={@save_status}
                      />
                    </div>

                    <div class="flex justify-end gap-2 pt-2 border-t border-base-300">
                      <button type="button" phx-click="cancel_edit" class="btn btn-ghost btn-sm">Cancel</button>
                      <button type="submit" class="btn btn-primary btn-sm">Save</button>
                    </div>
                  </div>
                </.form>
              <% else %>
                <div class="prose prose-base dark:prose-invert max-w-none">
                  {render_markdown(@page.body,
                    context_id: @page.context_id,
                    inline_links: Map.get(@page.meta || %{}, "inline_links", [])
                  )}
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
              <.page_graph id="note-page-graph" nodes={@graph_nodes} edges={@graph_edges} />
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
       editing: false,
       save_status: "idle"
     )}
  end

  def handle_params(%{"slug" => slug} = params, _url, socket) do
    context = socket.assigns.context

    if context do
      case Brain.get_page_by_slug(slug, context.id) do
        nil ->
          {:noreply, push_navigate(socket, to: ~p"/notes")}

        page ->
          relations = Brain.list_relations_for_page(page.id)
          versions = Brain.list_page_versions(page.id)
          logs = Brain.list_log(context_id: context.id, limit: 10)
          %{nodes: graph_nodes, edges: graph_edges} = GraphHelpers.build_page_subgraph(page)
          editing = Map.get(params, "edit") == "true"

          form =
            if editing do
              Brain.change_page(page) |> to_form(as: :page)
            else
              nil
            end

          {:noreply,
           assign(socket,
             page: page,
             relations: relations,
             versions: versions,
             logs: logs,
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
      {:noreply, push_navigate(socket, to: ~p"/notes")}
    end
  end

  def handle_params(_params, _url, socket) do
    pages =
      if socket.assigns.context do
        Brain.list_pages(context_id: socket.assigns.context.id, type: @page_type)
      else
        []
      end

    {:noreply, assign(socket, pages: pages, page_title: "Notes")}
  end

  # ── Graph events (from GraphEvents import) ──

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, switch_tab(socket, tab)}
  end

  def handle_event("node_click", %{"slug" => slug}, socket) do
    {:noreply, node_click(socket, slug)}
  end

  def handle_event("node_drag", %{"id" => id, "x" => x, "y" => y}, socket) do
    {:noreply, node_drag(socket, id, x, y)}
  end

  # ── Page navigation ──

  def handle_event("show_page", %{"slug" => slug}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/notes/#{slug}")}
  end

  def handle_event("new_page", _params, socket) do
    {:noreply, push_navigate(socket, to: ~p"/notes/new")}
  end

  # ── Editing (delegated to PageEdit) ──

  def handle_event("toggle_edit", params, socket),
    do: PageEdit.handle_event("toggle_edit", params, socket)

  def handle_event("cancel_edit", params, socket),
    do: PageEdit.handle_event("cancel_edit", params, socket)

  def handle_event("validate_page", params, socket),
    do: PageEdit.handle_event("validate_page", params, socket)

  def handle_event("save_page", params, socket),
    do: PageEdit.handle_event("save_page", params, socket)

  def handle_event("body_change", params, socket),
    do: PageEdit.handle_event("body_change", params, socket)

  def handle_event("field_change", params, socket),
    do: PageEdit.handle_event("field_change", params, socket)

  def handle_event("request_upload", params, socket),
    do: PageEdit.handle_event("request_upload", params, socket)

  def handle_event("upload_complete", params, socket),
    do: PageEdit.handle_event("upload_complete", params, socket)

  # ── Upload progress ──

  defp handle_progress(:file, _entry, socket) do
    {:noreply, socket}
  end
end
