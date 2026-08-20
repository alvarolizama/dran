defmodule DranWeb.PlanLive do
  @moduledoc "LiveView for plan pages: index list + detail view with inline editing."

  use DranWeb, :live_view
  on_mount {DranWeb.DisabledTypes, "plan"}

  alias Dran.Brain
  alias DranWeb.PageEdit
  alias DranWeb.PageTypes
  alias DranWeb.ListPagination
  alias DranWeb.Plugs.Auth

  @page_type "plan"

  alias DranWeb.DisabledTypes

  @plan_tabs [
    {"todos", gettext("Tareas")}
  ]

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
          content_hidden={@active_tab != "content"}
          content_tab_value="content"
          active_tab={@active_tab}
          editing={@editing}
        >
          <:actions>
            <.link navigate={~p"/panel/plans"} class="btn btn-primary btn-sm"><.icon
              name="hero-arrow-left"
              class="size-4"
            /> {gettext("Back")}</.link>
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
              workspace_id={@workspace_id}
              editor_id="plan-editor"
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
              workspace_id={@workspace_id}
              save_status={@save_status}
              editor_id="plan-editor"
            />
          </:tabs>

          <:extra_tabs>
            <button
              :for={{tab, label} <- @plan_tabs}
              phx-click="switch_tab"
              phx-value-tab={tab}
              class={[
                "px-3 py-2 text-sm font-medium border-b-2 -mb-px transition-colors duration-150",
                @active_tab == tab && "border-primary text-primary",
                @active_tab != tab &&
                  "border-transparent text-base-content/60 hover:text-base-content hover:border-base-content/20"
              ]}
            >
              {label}
            </button>
          </:extra_tabs>

          <:extra_content>
            <%!-- Todos: lista simple --%>
            <div :if={@active_tab == "todos"}>
              <div class="text-sm text-base-content/60 mb-3">
                {length(@plan_todos)} {gettext("todos linked")}
              </div>
              <div :for={todo <- @plan_todos} class="p-3 rounded-lg border border-base-300 mb-2">
                <.link
                  navigate={PageTypes.page_show_path(todo)}
                  class="font-medium text-primary hover:underline"
                >
                  {todo.title}
                </.link>
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

    if context && connected?(socket) do
      Phoenix.PubSub.subscribe(Dran.PubSub, "brain:#{context.id}")
    end

    {:ok,
     assign(socket,
       context: context,
       page_type: @page_type,
       plan_tabs: DisabledTypes.visible_tabs(@plan_tabs, context),
       active_tab: "content",
       editing: false,
       save_status: "idle",
       community_summary: nil,
       active_nav: "plans"
     )}
  end

  @impl true
  def handle_params(%{"slug" => slug} = params, _url, socket) do
    {socket, context} = Auth.resolve_workspace(socket, params)

    if context do
      case Brain.get_page_by_slug(slug, context.id) do
        nil ->
          {:noreply, push_navigate(socket, to: ~p"/panel/plans")}

        page ->
          relations = Brain.list_relations_for_page(page.id)
          versions = Brain.list_page_versions(page.id)
          logs = Brain.list_log(workspace_id: context.id, limit: 10)

          form = Brain.change_page(page) |> to_form(as: :page)

          # §7.2 — load todos linked to this plan via meta.plan_slug.
          # Brain.list_pages already supports a :plan_slug filter (Phase 2),
          # so we use it directly here instead of filtering in memory.
          plan_todos =
            Brain.list_pages(
              workspace_id: context.id,
              type: "todo",
              plan_slug: page.slug,
              include_body: false,
              limit: 500
            )

          rendered_body =
            render_markdown(page.body,
              workspace_id: page.workspace_id,
              inline_links: Map.get(page.meta || %{}, "inline_links", [])
            )

          community_summary =
            try do
              case Dran.Graph.CommunitySummaries.get_summary_for_page(page.id) do
                {:ok, summary} -> summary
                _ -> nil
              end
            rescue
              _ -> nil
            end

          {:noreply,
           assign(socket,
             page: page,
             relations: relations,
             versions: versions,
             compare_version: nil,
             logs: logs,
             page_title: page.title,
             active_tab: "content",
             community_summary: community_summary,
             plan_todos: plan_todos,
             editing: Map.get(params, "edit") == "true",
             form: form,
             context: context,
             workspace_id: context.id,
             plan_tabs: DisabledTypes.visible_tabs(@plan_tabs, context),
             save_status: "idle",
             rendered_body: rendered_body
           )}
      end
    else
      {:noreply, push_navigate(socket, to: ~p"/panel/plans")}
    end
  end

  def handle_params(_params, _url, socket) do
    {pages, archived_pages} =
      if socket.assigns.context do
        {Brain.list_pages(workspace_id: socket.assigns.context.id, type: @page_type),
         Brain.list_pages(
           workspace_id: socket.assigns.context.id,
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
       page_title: gettext("Plans")
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
    do: {:noreply, push_navigate(socket, to: ~p"/panel/plans/#{slug}")}

  def handle_event("show_todo", %{"slug" => slug}, socket),
    do: {:noreply, push_navigate(socket, to: ~p"/panel/todos/#{slug}")}

  def handle_event("change_status", %{"slug" => slug, "status" => status}, socket) do
    case update_page_meta(socket, slug, &Map.put(&1, "status", status)) do
      {:ok, socket} -> {:noreply, socket}
      {:error, socket} -> {:noreply, socket}
    end
  end

  def handle_event("noop", _params, socket), do: {:noreply, socket}

  # Override archive_page so the card disappears from the index list.
  def handle_event("archive_page", %{"slug" => slug} = params, socket) do
    if socket.assigns.live_action == :show do
      PageEdit.handle_event("archive_page", params, socket)
    else
      context = socket.assigns.context

      case context && Brain.get_page_by_slug(slug, context.id) do
        nil ->
          {:noreply, socket}

        page ->
          case Brain.archive_page(page) do
            {:ok, _updated} ->
              pages = Enum.reject(socket.assigns.pages, &(&1.slug == slug))
              archived_pages = [page | socket.assigns[:archived_pages] || []]
              {:noreply, assign(socket, pages: pages, archived_pages: archived_pages)}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, gettext("Could not archive page."))}
          end
      end
    end
  end

  def handle_event("new_page", _params, socket),
    do: {:noreply, push_navigate(socket, to: ~p"/panel/plans/new")}

  def handle_event("delete_page", p, s), do: PageEdit.handle_event("delete_page", p, s)

  def handle_event("toggle_pinned", p, s),
    do: PageEdit.handle_event("toggle_pinned", p, s)

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

  # Updates a page's meta in the DB and replaces it in the `pages` assign list.
  defp update_page_meta(socket, slug, updater) do
    context = socket.assigns.context

    if context do
      case Brain.get_page_by_slug(slug, context.id) do
        nil ->
          {:error, put_flash(socket, :error, gettext("Page not found."))}

        page ->
          new_meta = updater.(page.meta || %{})

          case Brain.update_page(page, %{"meta" => new_meta}) do
            {:ok, updated} ->
              pages =
                Enum.map(socket.assigns.pages, fn p ->
                  if p.slug == slug, do: updated, else: p
                end)

              {:ok, assign(socket, pages: pages)}

            {:error, _} ->
              {:error, put_flash(socket, :error, gettext("Could not update page."))}
          end
      end
    else
      {:error, socket}
    end
  end

  # ── PubSub: real-time update when a page changes ──

  @impl true
  def handle_info({:page_changed, _action, changed_page}, socket) do
    if socket.assigns[:page] && socket.assigns.page.id == changed_page.id do
      page = Brain.get_page(changed_page.id)

      if page do
        rendered_body =
          render_markdown(page.body,
            workspace_id: page.workspace_id,
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
