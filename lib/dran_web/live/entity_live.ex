defmodule DranWeb.EntityLive do
  @moduledoc "LiveView for entity pages: index list + detail view with inline editing."

  use DranWeb, :live_view
  on_mount {DranWeb.DisabledTypes, "entity"}

  alias Dran.Brain
  alias DranWeb.PageDetail
  alias DranWeb.PageEdit
  alias DranWeb.PageTypes
  alias DranWeb.ListPagination

  @page_type "entity"
  @impl true
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
          active_tab={@active_tab}
        >
          <:actions>
            <.link navigate={~p"/panel/entities"} class="btn btn-primary btn-sm">
              <.icon name="hero-arrow-left" class="size-4" /> {gettext("Back")}
            </.link>
            <.link navigate={~p"/panel/graph/#{@page.slug}"} class="btn btn-ghost btn-sm">
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
              editor_id="entity-editor"
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

  @impl true
  def mount(_params, session, socket) do
    PageDetail.mount_page_viewer(socket, session,
      page_type: @page_type,
      active_nav: "entities"
    )
  end

  @impl true
  def handle_params(%{"slug" => slug} = params, _url, socket) do
    PageDetail.load_page_detail(socket, params, slug, redirect_to: "/panel/entities")
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

  def handle_event("switch_tab", %{"tab" => tab}, socket), do: {:noreply, switch_tab(socket, tab)}

  def handle_event("show_page", %{"slug" => slug}, socket),
    do: {:noreply, push_navigate(socket, to: ~p"/panel/entities/#{slug}")}

  def handle_event("new_page", _params, socket),
    do: {:noreply, push_navigate(socket, to: ~p"/panel/entities/new")}

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

  # ── PubSub: real-time update when a page changes ──

  @impl true
  def handle_info({:page_changed, _action, changed_page}, socket) do
    if socket.assigns[:page] && socket.assigns.page.id == changed_page.id do
      page = Brain.get_page(changed_page.id)

      if page do
        rendered_body =
          render_markdown(page.body,
            context_id: page.context_id,
            inline_links: Map.get(page.meta || %{}, "inline_links", [])
          )

        form = Brain.change_page(page) |> to_form(as: :page)

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
end
