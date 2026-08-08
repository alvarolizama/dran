defmodule DranWeb.EntityLive do
  @moduledoc "LiveView for entity pages: index list + detail view with inline editing."

  use DranWeb, :live_view

  alias Dran.Brain
  alias DranWeb.GraphHelpers
  alias DranWeb.PageEdit
  alias DranWeb.ListPagination
  alias DranWeb.Plugs.Auth

  @page_type "entity"
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
          editing={@editing}
          content_tab_value="content"
          content_hidden={@active_tab != "content"}
          graph_active={@active_tab == "graph"}
          active_tab={@active_tab}
        >
          <:actions>
            <.link navigate={~p"/entities"} class="btn btn-primary btn-sm">
              <.icon name="hero-arrow-left" class="size-4" /> {gettext("Back")}
            </.link>
          </:actions>

          <:attributes>
            <.page_attributes
              form={@form}
              page={@page}
              page_type={@page_type}
              context_id={@context_id}
              editor_id="entity-editor"
            />
          </:attributes>

          <:graph>
            <.graph_3d
              id="entity-page-graph"
              nodes={@graph_nodes}
              edges={@graph_edges}
              class="w-full"
              style="height: calc(100vh - 200px);"
            />
          </:graph>

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

          <:tabs>
            <.page_edit_form
              form={@form}
              page={@page}
              page_type={@page_type}
              context_id={@context_id}
              save_status={@save_status}
              editor_id="entity-editor"
            />
          </:tabs>
        </.page_detail>
      </div><div :if={@live_action != :show}>
        <.page_list
          pages={Enum.take(@pages, @visible_count)}
          archived_pages={
            if @show_archived, do: Enum.take(@archived_pages, @archived_visible_count), else: []
          }
          archived_filter={@archived_filter}
          page_type={@page_type}
          context_slug={@context_slug}
          show_archived={@show_archived}
          total_count={length(@pages)}
          total_archived={length(@archived_pages)}
        />
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
       active_tab: "content",
       editing: true,
       save_status: "idle",
       active_nav: "entities",
       community_summary: nil
     )}
  end

  def handle_params(%{"slug" => slug} = params, _url, socket) do
    {socket, context} = Auth.resolve_context(socket, params)

    if context do
      case Brain.get_page_by_slug(slug, context.id) do
        nil ->
          {:noreply, push_navigate(socket, to: ~p"/entities")}

        page ->
          relations = Brain.list_relations_for_page(page.id)
          versions = Brain.list_page_versions(page.id)
          logs = Brain.list_log(context_id: context.id, limit: 10)

          %{nodes: graph_nodes, edges: graph_edges} =
            GraphHelpers.build_page_subgraph(page, relations: relations)

          form = Brain.change_page(page) |> to_form(as: :page)

          community_summary =
            try do
              case Dran.Graph.CommunitySummaries.get_summary_for_page(page.id) do
                {:ok, summary} -> summary
                _ -> nil
              end
            rescue
              _ -> nil
            end

          rendered_body =
            render_markdown(page.body,
              context_id: page.context_id,
              inline_links: Map.get(page.meta || %{}, "inline_links", [])
            )

          active_tab = Map.get(socket.assigns, :active_tab, "content")

          {:noreply,
           assign(socket,
             page: page,
             relations: relations,
             versions: versions,
             compare_version: nil,
             logs: logs,
             page_title: page.title,
             active_tab: active_tab,
             graph_nodes: graph_nodes,
             graph_edges: graph_edges,
             community_summary: community_summary,
             editing: true,
             form: form,
             context_id: context.id,
             save_status: "idle",
             rendered_body: rendered_body
           )}
      end
    else
      {:noreply, push_navigate(socket, to: ~p"/entities")}
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
       visible_count: 30,
       show_archived: false,
       archived_visible_count: 30,
       page_title: gettext("Entities")
     )}
  end

  def handle_event("filter_archived", %{"type" => type}, socket) do
    {:noreply, assign(socket, archived_filter: type)}
  end

  def handle_event("load_more", _params, socket),
    do: {:noreply, ListPagination.handle_load_more(socket)}

  def handle_event("toggle_archived", _params, socket),
    do: {:noreply, ListPagination.handle_toggle_archived(socket)}

  def handle_event("load_more_archived", _params, socket),
    do: {:noreply, ListPagination.handle_load_more_archived(socket)}

  def handle_event("switch_tab", %{"tab" => tab}, socket), do: {:noreply, switch_tab(socket, tab)}

  def handle_event("node_click", %{"slug" => slug}, socket),
    do: {:noreply, node_click(socket, slug)}

  def handle_event("show_page", %{"slug" => slug}, socket),
    do: {:noreply, push_navigate(socket, to: ~p"/entities/#{slug}")}

  def handle_event("new_page", _params, socket),
    do: {:noreply, push_navigate(socket, to: ~p"/entities/new")}

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
end
