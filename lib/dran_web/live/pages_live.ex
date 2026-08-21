defmodule DranWeb.PagesLive do
  @moduledoc """
  Generic LiveView for all page types (note, concept, entity, reference).

  Replaces the per-type LiveViews (NoteLive, ConceptLive, EntityLive,
  ReferenceLive). The page type is resolved from the URL params, not
  hardcoded — making this a single thin wrapper over PageDetail.
  """

  use DranWeb, :live_view

  alias Dran.Knowledge
  alias DranWeb.PageDetail
  alias DranWeb.PageEdit
  alias DranWeb.PageTypes
  alias DranWeb.ListPagination

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_user={@current_user}
      workspace_slug={@workspace_slug}
      workspaces={@workspaces}
      active_nav={@active_nav}
    >
      <div :if={@live_action == :show}>
        <.page_detail
          page={@page}
          relations={@relations}
          versions={@versions}
          compare_version={@compare_version}
          logs={@logs}
          workspace_slug={@workspace_slug}
          rendered_body={@rendered_body}
          editing={@editing}
          content_tab_value="content"
          content_hidden={@active_tab != "content"}
          active_tab={@active_tab}
        >
          <:actions>
            <.link navigate={@back_path} class="btn btn-primary btn-sm">
              <.icon name="hero-arrow-left" class="size-4" /> {gettext("Back")}
            </.link>
            <.link
              :if={@workspace_slug}
              navigate={~p"/#{@workspace_slug}/graph"}
              class="btn btn-ghost btn-sm"
            >
              <.icon name="hero-share" class="size-4" /> {gettext("Graph")}
            </.link>
            <.link :if={@editing} patch={@page_path} class="btn btn-ghost btn-sm">
              <.icon name="hero-eye" class="size-4" /> {gettext("View")}
            </.link>
            <.link
              :if={not @editing}
              patch={@page_path <> "?edit=true"}
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
              workspace_id={@workspace_id}
              editor_id={"#{@page_type}-editor"}
            />
          </:attributes>

          <:insights>
            <div class="space-y-4">
              <div :if={@community_summary} class="surface-2 rounded-lg p-4">
                <h3 class="text-sm font-semibold mb-2">{gettext("Community Context")}</h3>
                <p class="text-sm text-base-content/70">{@community_summary.summary}</p>
                <p class="text-xs text-base-content/40 mt-1">
                  {gettext("Community")} {@community_summary.community_id} · {@community_summary.page_count} {gettext(
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
            <.page_edit_form
              form={@form}
              page={@page}
              page_type={@page_type}
              workspace_id={@workspace_id}
              save_status={@save_status}
              editor_id={"#{@page_type}-editor"}
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
          workspace_slug={@workspace_slug}
          show_archived={@show_archived}
          total_count={length(@pages)}
          total_archived={length(@archived_pages)}
        />
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(params, session, socket) do
    page_type = page_type_from_params(params)

    if page_type not in PageTypes.keys() do
      {:ok, push_navigate(socket, to: ~p"/")}
    else
      PageDetail.mount_page_viewer(socket, session,
        page_type: page_type,
        active_nav: PageTypes.path(page_type)
      )
    end
  end

  @impl true
  def handle_params(%{"slug" => slug} = params, _url, socket) do
    page_type = socket.assigns[:page_type] || page_type_from_params(params)
    workspace_slug = socket.assigns[:workspace_slug] || params["workspace_slug"]
    back_path = build_back_path(workspace_slug, page_type)
    page_path = build_page_path(workspace_slug, page_type, slug)

    # Alias workspace_slug → workspace so Auth.resolve_workspace finds it
    params = Map.put(params, "workspace", workspace_slug)

    socket = assign(socket, back_path: back_path, page_path: page_path)

    PageDetail.load_page_detail(socket, params, slug, redirect_to: back_path)
  end

  def handle_params(params, _url, socket) do
    page_type = socket.assigns[:page_type] || page_type_from_params(params)
    workspace_slug = socket.assigns[:workspace_slug] || params["workspace_slug"]

    {pages, archived_pages} =
      if socket.assigns.context do
        {Knowledge.list_pages(workspace_id: socket.assigns.context.id, type: page_type),
         Knowledge.list_pages(
           workspace_id: socket.assigns.context.id,
           type: page_type,
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
       page_title: PageTypes.plural(page_type),
       back_path: build_back_path(workspace_slug, page_type)
     )}
  end

  # ── Pagination + filter events ──

  @impl true
  def handle_event("filter_archived", %{"type" => type}, socket) do
    {:noreply, assign(socket, archived_filter: type)}
  end

  def handle_event("load_more", _params, socket),
    do: {:noreply, ListPagination.handle_load_more(socket)}

  def handle_event("toggle_archived", _params, socket),
    do: {:noreply, ListPagination.handle_toggle_archived(socket)}

  def handle_event("load_more_archived", _params, socket),
    do: {:noreply, ListPagination.handle_load_more_archived(socket)}

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, active_tab: tab)}
  end

  # ── Page navigation ──

  def handle_event("show_page", %{"slug" => slug}, socket) do
    page_type = socket.assigns[:page_type]
    workspace_slug = socket.assigns[:workspace_slug]
    {:noreply, push_navigate(socket, to: build_page_path(workspace_slug, page_type, slug))}
  end

  def handle_event("new_page", _params, socket) do
    page_type = socket.assigns[:page_type]
    workspace_slug = socket.assigns[:workspace_slug]
    type_path = PageTypes.path(page_type)
    {:noreply, push_navigate(socket, to: ~p"/#{workspace_slug}/#{type_path}/new")}
  end

  # ── Editing (delegated to PageEdit) ──

  def handle_event("delete_page", params, socket),
    do: PageEdit.handle_event("delete_page", params, socket)

  def handle_event("toggle_pinned", params, socket),
    do: PageEdit.handle_event("toggle_pinned", params, socket)

  def handle_event("archive_page", params, socket),
    do: PageEdit.handle_event("archive_page", params, socket)

  def handle_event("unarchive_page", params, socket),
    do: PageEdit.handle_event("unarchive_page", params, socket)

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

  # ── Version comparison ──

  def handle_event("compare_version", params, socket),
    do: DranWeb.VersionCompare.handle_event("compare_version", params, socket)

  def handle_event("clear_compare", params, socket),
    do: DranWeb.VersionCompare.handle_event("clear_compare", params, socket)

  # ── PubSub: real-time update when a page changes ──

  @impl true
  def handle_info({:page_changed, _action, changed_page}, socket) do
    if socket.assigns[:page] && socket.assigns.page.id == changed_page.id do
      page = Knowledge.get_page(changed_page.id)

      if page do
        rendered_body =
          render_markdown(page.body,
            workspace_id: page.workspace_id,
            inline_links: Map.get(page.meta || %{}, "inline_links", [])
          )

        form = Knowledge.change_page(page) |> to_form(as: :page)

        {:noreply,
         assign(socket,
           page: page,
           rendered_body: rendered_body,
           form: form
         )}
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── Helpers ──

  defp page_type_from_params(%{"type" => type_path}) when is_binary(type_path) do
    PageTypes.type_from_path(type_path)
  end

  defp page_type_from_params(%{"page_type" => type_path}) when is_binary(type_path) do
    PageTypes.type_from_path(type_path)
  end

  defp page_type_from_params(_), do: nil

  defp build_back_path(nil, page_type), do: "/#{PageTypes.path(page_type)}"
  defp build_back_path(workspace_slug, page_type), do: "/#{workspace_slug}/#{PageTypes.path(page_type)}"

  defp build_page_path(nil, page_type, slug), do: "/#{PageTypes.path(page_type)}/#{slug}"
  defp build_page_path(workspace_slug, page_type, slug),
    do: "/#{workspace_slug}/#{PageTypes.path(page_type)}/#{slug}"

end
