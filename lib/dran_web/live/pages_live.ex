defmodule DranWeb.PagesLive do
  @moduledoc """
  Generic LiveView for all page types (note, concept, entity, reference).

  Replaces the per-type LiveViews (NoteLive, ConceptLive, EntityLive,
  ReferenceLive). The page type is resolved from the URL params, not
  hardcoded — making this a single thin wrapper over PageDetail.
  """

  use DranWeb, :live_view

  alias Dran.Knowledge
  alias Dran.Knowledge.Page
  alias Dran.Workspace
  alias DranWeb.Components.ShareDialog
  alias DranWeb.PageDetail
  alias DranWeb.PageEdit
  alias DranWeb.ListPagination
  alias DranWeb.Plugs.Auth

  @impl true
  def render(assigns) do
    # The modal flag is only assigned when handle_params ran a branch that
    # manages the create modal — normalize so show/index always render.
    assigns = assign(assigns, modal_open: Map.get(assigns, :modal_open, false))

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_user={@current_user}
      user={@user}
      workspace_slug={@workspace_slug}
      active_nav={@active_nav}
    >
      <div :if={@live_action == :show}>
        <ShareDialog.share_dialog
          open={@share_open || false}
          resource_type="page"
          resource_id={@page && @page.id}
          shares={@shares || []}
          users={@share_users || []}
          groups={@share_groups || []}
        />

        <.page_detail
          page={@page}
          share_target={true}
          creator_labels={@creator_labels}
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
            <.link navigate={@back_path} class="btn btn-ghost btn-sm">
              <.icon name="hero-arrow-left" class="size-4" /> {gettext("Back")}
            </.link>
            <.link
              :if={@workspace_slug}
              navigate={~p"/graph"}
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
              <div :if={@cluster_summary} class="surface-2 rounded-lg p-4">
                <h3 class="text-sm font-semibold mb-2">{gettext("Cluster Context")}</h3>
                <p class="text-sm text-base-content/70">{@cluster_summary.summary}</p>
                <p class="text-xs text-base-content/40 mt-1">
                  {gettext("Cluster")} {@cluster_summary.cluster_id} · {@cluster_summary.page_count} {gettext(
                    "pages"
                  )}
                </p>
              </div>
              <div
                :if={!@cluster_summary}
                class="text-sm text-base-content/40 text-center py-8"
              >
                {gettext("No cluster data yet. Run cluster summaries first.")}
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
      </div>

      <div :if={@live_action == :index}>
        <.page_list
          pages={Enum.take(@pages, @visible_count)}
          archived_pages={
            if @show_archived, do: Enum.take(@archived_pages, @archived_visible_count), else: []
          }
          archived_filter={@archived_filter}
          page_type={@page_type}
          workspace_slug={@workspace_slug}
          context={@context}
          show_archived={@show_archived}
          total_count={length(@pages)}
          total_archived={length(@archived_pages)}
        />
      </div>

      <.resource_modal
        :if={@modal_open || false}
        id="page-resource-modal"
        title={gettext("New Page")}
        pill={(@page_type && String.upcase(@page_type)) || "PAGE"}
        pill_class="bg-primary/10 text-primary"
        on_close="close_page_modal"
        form_id="page-new-form-#{@page_type}"
        submit_label={gettext("Create")}
      >
        <.page_new_form
          form={@form}
          page_type={@page_type}
          workspace_id={@workspace_id}
          editor_id={"#{@page_type}-new-editor"}
          cancel_path={@back_path}
        />
      </.resource_modal>
    </Layouts.app>
    """
  end

  @impl true
  def mount(params, session, socket) do
    # Resolve the workspace BEFORE the type gate so a path declared by the
    # workspace's own custom types is not a 404: `page_types` is
    # built-in ∪ custom, not the global registry alone.
    socket = resolve_mount_workspace(socket, params, session)

    case page_type_from_params(params, socket.assigns[:context]) do
      nil ->
        # Legacy multi-workspace URL landing on the flat router: the first
        # segment is a retired workspace slug, not a type path. The router
        # puts `/:type(/:slug)` ahead of the legacy redirect routes, so the
        # hop lives HERE: drop the slug segment and navigate (D2). A
        # genuinely unknown single segment ends at "/" (the old router
        # flashed "no access" and sent the user home too).
        target =
          case params do
            %{"slug" => slug} -> "/" <> slug
            _ -> "/"
          end

        {:ok, push_navigate(socket, to: target)}

      page_type ->
        PageDetail.mount_page_viewer(socket, params, session,
          page_type: page_type,
          active_nav: Workspace.page_type_path(socket.assigns[:context], page_type)
        )
    end
  end

  # Resolves the workspace from the URL slug (falling back to the session) so
  # the type gate has the right effective-types list. Never raises: an
  # unresolvable workspace leaves `context` nil and the gate falls back to the
  # built-in types.
  defp resolve_mount_workspace(socket, params, session) do
    case Auth.assign_to_socket(socket, session, params) do
      {socket, %Dran.Workspace{} = context} -> assign(socket, context: context)
      {socket, _} -> socket
    end
  end

  @impl true
  def handle_params(%{"slug" => slug} = params, _url, socket) do
    # `?new=true` overrides — the slug clause only handles show; a
    # `?new=true` on a show URL opens the create modal (handled by the
    # generic clause below, which sets modal_open + a fresh form).
    if params["new"] == "true" do
      params =
        Map.put(params, "workspace", socket.assigns[:workspace_slug] || params["workspace_slug"])

      handle_params(params, nil, socket)
    else
      context = socket.assigns[:context]
      page_type = socket.assigns[:page_type] || page_type_from_params(params, context)
      workspace_slug = socket.assigns[:workspace_slug] || params["workspace_slug"]
      back_path = build_back_path(workspace_slug, context, page_type)
      page_path = build_page_path(workspace_slug, context, page_type, slug)

      # Alias workspace_slug → workspace so Auth.resolve_workspace finds it
      params = Map.put(params, "workspace", workspace_slug)

      socket = assign(socket, back_path: back_path, page_path: page_path)

      PageDetail.load_page_detail(socket, params, slug, redirect_to: back_path)
    end
  end

  # `?new=true` forwards to the create-modal action (the slug clause and the
  # generic index clause both route here). The `/new` ROUTE is gone — the
  # create modal is URL state, not a page.

  def handle_params(params, _url, socket) do
    context = socket.assigns[:context]
    page_type = socket.assigns[:page_type] || page_type_from_params(params, context)
    workspace_slug = socket.assigns[:workspace_slug] || params["workspace_slug"]

    scope = page_scope(socket)

    {pages, archived_pages} =
      if socket.assigns.context do
        {Knowledge.list_pages(
           workspace_id: socket.assigns.context.id,
           type: page_type,
           limit: 500,
           scope: scope
         ),
         Knowledge.list_pages(
           workspace_id: socket.assigns.context.id,
           type: page_type,
           archived: true,
           limit: 200,
           scope: scope
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
       page_title: Workspace.page_type_plural(context, page_type),
       back_path: build_back_path(workspace_slug, context, page_type),
       # Create-modal state (?new=true) — form + workspace for the editor
       modal_open: params["new"] == "true",
       workspace_id: socket.assigns.context && socket.assigns.context.id,
       form:
         if params["new"] == "true" do
           to_form(Knowledge.change_page(%Page{page_type: page_type}), as: :page)
         else
           socket.assigns[:form]
         end
     )}
  end

  # ── Pagination events ──

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
    context = socket.assigns[:context]

    {:noreply,
     push_navigate(socket, to: build_page_path(workspace_slug, context, page_type, slug))}
  end

  def handle_event("new_page", _params, socket) do
    page_type = socket.assigns[:page_type]
    type_path = Workspace.page_type_path(socket.assigns[:context], page_type)
    {:noreply, push_patch(socket, to: ~p"/#{type_path}?new=true")}
  end

  def handle_event("close_page_modal", _params, socket) do
    page_type = socket.assigns[:page_type]
    type_path = Workspace.page_type_path(socket.assigns[:context], page_type)

    {:noreply, push_patch(socket, to: ~p"/#{type_path}")}
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

  def handle_event(
        "open_share",
        _params,
        %{assigns: %{page: %Dran.Knowledge.Page{} = page}} = socket
      ) do
    {:noreply,
     socket
     |> assign(:share_open, true)
     |> assign(:shares, Dran.Sharing.list_shares("page", page.id))
     |> assign(:share_users, Dran.Accounts.list_users())
     |> assign(:share_groups, Dran.Sharing.list_groups())}
  end

  def handle_event("open_share", _params, socket), do: {:noreply, socket}

  def handle_event("close_share", _params, socket) do
    {:noreply, assign(socket, :share_open, false)}
  end

  def handle_event("noop", _params, socket), do: {:noreply, socket}

  def handle_event("share_with_user", %{"user_id" => user_id}, %{assigns: %{page: page}} = socket)
      when user_id != "" do
    case Dran.Sharing.share_with_user("page", page.id, String.to_integer(user_id)) do
      {:ok, :shared} ->
        {:noreply,
         socket
         |> assign(:shares, Dran.Sharing.list_shares("page", page.id))
         |> put_flash(:info, gettext("Shared."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not share."))}
    end
  end

  def handle_event("share_with_user", _params, socket), do: {:noreply, socket}

  def handle_event(
        "share_with_group",
        %{"group_id" => group_id},
        %{assigns: %{page: page}} = socket
      )
      when group_id != "" do
    case Dran.Sharing.share_with_group("page", page.id, String.to_integer(group_id)) do
      {:ok, :shared} ->
        {:noreply,
         socket
         |> assign(:shares, Dran.Sharing.list_shares("page", page.id))
         |> put_flash(:info, gettext("Shared."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not share."))}
    end
  end

  def handle_event("share_with_group", _params, socket), do: {:noreply, socket}

  def handle_event("unshare", %{"id" => share_id}, %{assigns: %{page: page}} = socket) do
    :ok = Dran.Sharing.unshare(share_id)
    {:noreply, assign(socket, :shares, Dran.Sharing.list_shares("page", page.id))}
  end

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

  defp page_type_from_params(%{"type" => type_path}, context)
       when is_binary(type_path) do
    workspace_type_from_path(context, type_path)
  end

  defp page_type_from_params(%{"page_type" => type_path}, context)
       when is_binary(type_path) do
    workspace_type_from_path(context, type_path)
  end

  defp page_type_from_params(_params, _context), do: nil

  # Built-in paths resolve first, then the workspace's own custom paths. When
  # mounts run without a resolved context (unauthenticated / non-workspace
  # URLs) the built-in registry is still the fallback, so the retired paths
  # keep 404ing.
  defp workspace_type_from_path(context, type_path) do
    case Dran.PageRegistry.type_from_path(type_path) do
      nil ->
        Workspace.page_type_by_path(context, type_path)

      type ->
        # A built-in path the workspace no longer knows still 404s (the
        # built-in set is stable, so this only guards a future retirement).
        if context == nil or Knowledge.effective_page_type?(context, type), do: type
    end
  end

  # Paths come from the workspace (custom types declare their own `path`), so
  # a custom page type's list and detail URLs are built from its declaration.
  defp build_back_path(nil, context, page_type),
    do: "/#{Workspace.page_type_path(context, page_type)}"

  defp build_back_path(_workspace_slug, context, page_type),
    do: "/#{Workspace.page_type_path(context, page_type)}"

  defp build_page_path(nil, context, page_type, slug),
    do: "/#{Workspace.page_type_path(context, page_type)}/#{slug}"

  defp build_page_path(_workspace_slug, context, page_type, slug),
    do: "/#{Workspace.page_type_path(context, page_type)}/#{slug}"

  # El scope de lectura sale del módulo único de política.
  defp page_scope(socket) do
    Dran.ContentVisibility.resolve(socket.assigns[:context], socket.assigns[:user], :pages)
  end
end
