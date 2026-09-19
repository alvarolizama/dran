defmodule DranWeb.AdminWorkspacesLive do
  @moduledoc """
  Admin workspace management (owner-only). Create/delete workspaces, toggle
  default, toggle page types (disabled_page_types), and link to the
  per-workspace settings page at /:ws/settings.

  No visibility control: every workspace is private and access is granted per
  account (see `Dran.Workspace.changeset/2`).
  """

  use DranWeb, :live_view

  alias Dran.Slug
  alias DranWeb.Plugs.Auth

  @impl true
  def mount(_params, session, socket) do
    {socket, _workspace} = Auth.assign_to_socket(socket, session)

    socket =
      socket
      |> assign(
        active_nav: "admin_workspaces",
        page_title: gettext("Workspaces"),
        workspace_slug: nil
      )
      |> assign_workspaces()
      |> assign_users()
      |> assign_workspace_form()
      |> assign(
        slug_touched: false,
        show_workspace_modal: false,
        editing_workspace: nil,
        form_modal_title: gettext("New workspace"),
        managing_workspace_id: nil,
        workspace_user_search: "",
        page_types_workspace_id: nil
      )

    {:ok, socket}
  end

  defp assign_workspaces(socket) do
    assign(socket, all_workspaces: Dran.Knowledge.list_workspaces())
  end

  defp assign_users(socket) do
    assign(socket, users: Dran.Accounts.list_users())
  end

  defp assign_workspace_form(socket) do
    assign(socket,
      workspace_form: to_form(Dran.Workspace.changeset(%Dran.Workspace{}, %{}), as: :workspace)
    )
  end

  @impl true
  def handle_event("new_workspace", _params, socket) do
    {:noreply,
     assign(socket,
       editing_workspace: nil,
       workspace_form: to_form(Dran.Workspace.changeset(%Dran.Workspace{}, %{}), as: :workspace),
       form_modal_title: gettext("New workspace"),
       show_workspace_modal: true
     )}
  end

  @impl true
  def handle_event("edit_workspace", %{"id" => id}, socket) do
    workspace = Dran.Knowledge.get_workspace!(id)

    {:noreply,
     assign(socket,
       editing_workspace: workspace,
       workspace_form: to_form(Dran.Workspace.changeset(workspace, %{}), as: :workspace),
       form_modal_title: gettext("Edit workspace"),
       show_workspace_modal: true
     )}
  end

  @impl true
  def handle_event("close_workspace_modal", _params, socket) do
    {:noreply, assign(socket, show_workspace_modal: false)}
  end

  @impl true
  def handle_event("validate_workspace", %{"workspace" => params, "_target" => target}, socket) do
    name = params["name"] || ""
    slug_touched = socket.assigns[:slug_touched] || false

    slug_touched =
      if target == ["workspace", "slug"], do: true, else: slug_touched

    params =
      if slug_touched do
        params
      else
        Map.put(params, "slug", Slug.slugify(name))
      end

    form = %Dran.Workspace{} |> Dran.Workspace.changeset(params) |> to_form(as: :workspace)
    {:noreply, assign(socket, workspace_form: form, slug_touched: slug_touched)}
  end

  @impl true
  def handle_event("save_workspace", %{"workspace" => params}, socket) do
    attrs = %{
      name: params["name"],
      is_default: not is_nil(params["is_default"])
    }

    case save_workspace(socket.assigns.editing_workspace, attrs) do
      {:ok, _workspace} ->
        {:noreply,
         socket
         |> assign_workspaces()
         |> assign_workspace_form()
         |> assign(slug_touched: false, editing_workspace: nil, show_workspace_modal: false)
         |> put_flash(:info, gettext("Workspace saved"))}

      {:error, changeset} ->
        {:noreply, assign(socket, workspace_form: to_form(changeset, as: :workspace))}
    end
  end

  @impl true
  def handle_event("delete_workspace", %{"id" => id}, socket) do
    workspace = Enum.find(socket.assigns.all_workspaces, &(&1.id == id))

    if workspace do
      case Dran.Knowledge.delete_workspace(workspace) do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign_workspaces()
           |> put_flash(
             :info,
             gettext(~s(Workspace "%{name}" deleted), name: workspace.name)
           )}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Could not delete workspace"))}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("manage_workspace_users", %{"id" => id}, socket) do
    {:noreply, assign(socket, managing_workspace_id: id, workspace_user_search: "")}
  end

  @impl true
  def handle_event("close_workspace_users", _params, socket) do
    {:noreply, assign(socket, managing_workspace_id: nil, workspace_user_search: "")}
  end

  @impl true
  def handle_event("manage_page_types", %{"id" => id}, socket) do
    {:noreply, assign(socket, page_types_workspace_id: id)}
  end

  @impl true
  def handle_event("close_page_types", _params, socket) do
    {:noreply, assign(socket, page_types_workspace_id: nil)}
  end

  @impl true
  def handle_event(
        "toggle_page_type",
        %{"workspace_id" => workspace_id, "page_type" => page_type},
        socket
      ) do
    workspace = Dran.Knowledge.get_workspace!(workspace_id)
    disabled = workspace.disabled_page_types || []

    new_disabled =
      if page_type in disabled do
        List.delete(disabled, page_type)
      else
        disabled ++ [page_type]
      end

    case Dran.Knowledge.update_workspace_settings(workspace, %{disabled_page_types: new_disabled}) do
      {:ok, _} -> {:noreply, assign_workspaces(socket)}
      {:error, _} -> {:noreply, put_flash(socket, :error, gettext("Could not update page types"))}
    end
  end

  @impl true
  def handle_event("search_workspace_users", %{"q" => q}, socket) do
    {:noreply, assign(socket, workspace_user_search: q)}
  end

  @impl true
  def handle_event(
        "toggle_workspace_user",
        %{"workspace_id" => workspace_id, "user_id" => user_id},
        socket
      ) do
    user = Dran.Accounts.get_user!(user_id)
    workspace = Dran.Knowledge.get_workspace!(workspace_id)

    if Dran.Accounts.user_in_workspace?(user, workspace) do
      Dran.Accounts.remove_user_from_workspace(user, workspace)
    else
      Dran.Accounts.add_user_to_workspace(user, workspace)
    end

    {:noreply, assign_users(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_user={@current_user}
      user={@user}
      workspace_slug={@workspace_slug}
      workspaces={@workspaces}
      active_nav={@active_nav}
      nav={:instance}
    >
      <div class="w-full">
        <div class="w-full space-y-6">
          <div class="flex flex-wrap items-center justify-between gap-3">
            <div>
              <h1 class="text-title">{gettext("Workspaces")}</h1>
              <p class="text-caption mt-1">
                {gettext("Create workspaces and manage access per user.")}
              </p>
            </div>
            <.button phx-click="new_workspace" id="new-workspace-admin-btn">
              <.icon name="hero-plus" class="size-4" />
              {gettext("New workspace")}
            </.button>
          </div>

          <%!-- Workspace list --%>
          <.section
            :if={@all_workspaces != []}
            title={gettext("Workspaces")}
            icon="hero-building-office-2"
          >
            <div class="overflow-x-auto">
              <table class="table table-sm">
                <thead>
                  <tr>
                    <th>{gettext("Workspace")}</th>
                    <th>{gettext("Members")}</th>
                    <th>{gettext("Default")}</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={ws <- @all_workspaces} id={"ws-#{ws.id}"}>
                    <td>
                      <div class="font-medium">{ws.name}</div>
                      <code class="text-xs text-base-content/60">{ws.slug}</code>
                    </td>
                    <td>{Enum.count(@users, &Dran.Accounts.user_in_workspace?(&1, ws))}</td>
                    <td>
                      <span :if={ws.is_default} class="badge badge-primary badge-sm">
                        {gettext("default")}
                      </span>
                    </td>
                    <td>
                      <div class="flex items-center gap-1 justify-end">
                        <button
                          phx-click="edit_workspace"
                          phx-value-id={ws.id}
                          class="btn btn-ghost btn-xs p-1"
                          title={gettext("Edit")}
                        >
                          <.icon name="hero-pencil" class="size-4" />
                        </button>
                        <button
                          phx-click="manage_workspace_users"
                          phx-value-id={ws.id}
                          class="btn btn-ghost btn-xs gap-1"
                        >
                          <.icon name="hero-users" class="size-3.5" />
                          {gettext("Users")}
                        </button>
                        <button
                          phx-click="manage_page_types"
                          phx-value-id={ws.id}
                          class="btn btn-ghost btn-xs gap-1"
                        >
                          <.icon name="hero-squares-2x2" class="size-3.5" />
                          {gettext("Types")}
                        </button>
                        <.link
                          navigate={"/#{ws.slug}/settings"}
                          class="btn btn-ghost btn-xs gap-1"
                          title={gettext("Configuration")}
                        >
                          <.icon name="hero-cog-6-tooth" class="size-3.5" />
                          {gettext("Config")}
                        </.link>
                        <button
                          phx-click="delete_workspace"
                          phx-value-id={ws.id}
                          data-confirm={gettext("Delete this workspace?")}
                          class="btn btn-ghost btn-xs p-1 text-error"
                          title={gettext("Delete")}
                        >
                          <.icon name="hero-trash" class="size-4" />
                        </button>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </.section>

          <div :if={@all_workspaces == []} class="text-center text-base-content/50 py-6">
            {gettext("No workspaces yet — create one with the button above.")}
          </div>

          <%!-- Add / edit workspace modal --%>
          <.modal
            :if={@show_workspace_modal}
            id="workspace-modal"
            title={@form_modal_title}
            on_close="close_workspace_modal"
          >
            <.form
              for={@workspace_form}
              id="workspace-form"
              phx-change="validate_workspace"
              phx-submit="save_workspace"
              class="space-y-4"
            >
              <.input
                field={@workspace_form[:name]}
                type="text"
                label={gettext("Name")}
                placeholder={gettext("e.g. Personal")}
                class="w-full"
                autofocus
              />

              <div>
                <label class="flex items-center gap-2">
                  <input
                    type="checkbox"
                    name="workspace[is_default]"
                    checked={@editing_workspace && @editing_workspace.is_default}
                    class="checkbox checkbox-sm"
                  />
                  <span class="text-sm">{gettext("Default workspace")}</span>
                </label>
                <p class="text-xs text-base-content/60 mt-1">
                  {gettext("Used when a user has no workspace of their own and no active session.")}
                </p>
              </div>

              <div class="flex justify-end gap-2 pt-2">
                <button type="button" phx-click="close_workspace_modal" class="btn btn-ghost btn-sm">
                  {gettext("Cancel")}
                </button>
                <button
                  type="submit"
                  class="btn btn-primary btn-sm"
                  phx-disable-with={gettext("Saving…")}
                >
                  {gettext("Save")}
                </button>
              </div>
            </.form>
          </.modal>

          <%!-- Page types modal --%>
          <.modal
            :if={@page_types_workspace_id != nil}
            id="page-types-modal"
            title={gettext("Page types")}
            on_close="close_page_types"
            max_w="max-w-md"
          >
            <% pt_ws = Enum.find(@all_workspaces, &(&1.id == @page_types_workspace_id)) %>
            <p class="text-caption mt-1">{if pt_ws, do: pt_ws.name, else: ""}</p>

            <p class="text-caption mt-1">
              {gettext(
                "Disabled types are hidden in the web UI and rejected by the agent tools for this workspace."
              )}
            </p>

            <div class="divide-y divide-base-300 mt-2">
              <label
                :for={page_type <- Dran.Knowledge.page_types()}
                class="flex items-center justify-between gap-3 py-2.5 cursor-pointer hover:bg-base-200/50 px-2 rounded-lg transition-colors"
              >
                <div class="min-w-0">
                  <p class="text-sm font-medium">{Dran.PageRegistry.label(page_type)}</p>
                  <p
                    :if={pt_ws && page_type in (pt_ws.disabled_page_types || [])}
                    class="text-xs text-error"
                  >
                    {gettext("Disabled")}
                  </p>
                  <p class="text-xs text-base-content/40">
                    {page_type_impact(page_type)}
                  </p>
                </div>
                <input
                  type="checkbox"
                  checked={pt_ws && page_type not in (pt_ws.disabled_page_types || [])}
                  phx-click="toggle_page_type"
                  phx-value-workspace_id={@page_types_workspace_id}
                  phx-value-page_type={page_type}
                  class="toggle toggle-sm toggle-primary"
                />
              </label>
            </div>
          </.modal>

          <%!-- Manage users modal --%>
          <.modal
            :if={@managing_workspace_id != nil}
            id="workspace-users-modal"
            title={gettext("Users")}
            on_close="close_workspace_users"
            max_w="max-w-md"
          >
            <% managing_ws = Enum.find(@all_workspaces, &(&1.id == @managing_workspace_id)) %>
            <p class="text-caption mt-1">{if managing_ws, do: managing_ws.name, else: ""}</p>

            <form
              id="workspace-user-search-form"
              phx-change="search_workspace_users"
              class="relative mt-3"
            >
              <.icon
                name="hero-magnifying-glass"
                class="absolute left-2.5 top-2.5 size-4 text-base-content/50"
              />
              <input
                type="text"
                name="q"
                value={@workspace_user_search}
                placeholder={gettext("Search users...")}
                class="w-full pl-8 pr-3 py-1.5 text-sm rounded-lg border border-base-300 bg-base-100 transition-colors duration-150 focus:outline-none focus:ring-1 focus:ring-primary"
              />
            </form>

            <div class="divide-y divide-base-300 mt-2 max-h-64 overflow-y-auto">
              <% filtered_users =
                @users
                |> Enum.filter(fn user ->
                  q = String.downcase(@workspace_user_search || "")

                  q == "" or String.contains?(String.downcase(user.email), q) or
                    (user.name && String.contains?(String.downcase(user.name), q))
                end)
                |> Enum.take(5) %>
              <label
                :for={user <- filtered_users}
                class="flex items-center justify-between gap-3 py-2.5 cursor-pointer hover:bg-base-200/50 px-2 rounded-lg transition-colors"
              >
                <div class="min-w-0">
                  <p class="text-sm font-medium truncate">{user.email}</p>
                  <p :if={user.name} class="text-caption truncate">{user.name}</p>
                </div>
                <input
                  type="checkbox"
                  checked={managing_ws && Dran.Accounts.user_in_workspace?(user, managing_ws)}
                  phx-click="toggle_workspace_user"
                  phx-value-workspace_id={@managing_workspace_id}
                  phx-value-user_id={user.id}
                  class="checkbox checkbox-sm"
                />
              </label>

              <p :if={filtered_users == []} class="text-caption py-4 text-center">
                {if @users == [],
                  do: gettext("No users yet — create one in the Users section."),
                  else: gettext("No users match your search.")}
              </p>
            </div>
          </.modal>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # Short human-readable hint shown next to each page type toggle.
  defp page_type_impact(type) do
    gettext("%{plural} section and %{path} list",
      plural: Dran.PageRegistry.plural(type),
      path: Dran.PageRegistry.path(type)
    )
  end

  defp save_workspace(nil, attrs), do: Dran.Knowledge.create_workspace(attrs)

  defp save_workspace(ws, attrs), do: Dran.Knowledge.update_workspace(ws, attrs)
end
