defmodule DranWeb.ReportLive do
  @moduledoc """
  LiveView for report pages: detail view only.

  Reports are second-citizen pages (see `Dran.Brain.PageTypes`) — created by
  the system (jobs, system output), never via MCP or the web UI. They live
  outside the graph, journey and embeddings, surface in the activity log,
  and are viewable here at `/reports/:slug`. There is intentionally no index
  or new form.
  """

  use DranWeb, :live_view
  on_mount {DranWeb.DisabledTypes, "report"}

  alias Dran.Brain
  alias DranWeb.PageDetail
  alias DranWeb.PageEdit
  alias DranWeb.PageTypes

  @page_type "report"
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
            <.link navigate={~p"/panel/activity"} class="btn btn-primary btn-sm">
              <.icon name="hero-arrow-left" class="size-4" /> {gettext("Back")}
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
              editor_id="report-editor"
            />
          </:attributes>

          <:insights>
            <div class="text-sm text-base-content/40 text-center py-8">
              {gettext("Reports are system-generated and do not participate in communities.")}
            </div>
          </:insights>

          <:tabs :if={@editing}>
            <.page_edit_form
              form={@form}
              page={@page}
              page_type={@page_type}
              context_id={@context_id}
              save_status={@save_status}
              editor_id="report-editor"
            />
          </:tabs>
        </.page_detail>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, session, socket) do
    PageDetail.mount_page_viewer(socket, session,
      page_type: @page_type,
      active_nav: "activity"
    )
  end

  @impl true
  def handle_params(%{"slug" => slug} = params, _url, socket) do
    PageDetail.load_page_detail(socket, params, slug, redirect_to: "/panel/activity")
  end

  # ── Tab switching ──

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, switch_tab(socket, tab)}
  end

  # ── Editing (delegated to PageEdit) ──

  def handle_event("delete_page", params, socket),
    do: PageEdit.handle_event("delete_page", params, socket)

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
