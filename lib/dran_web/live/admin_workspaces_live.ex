defmodule DranWeb.AdminWorkspacesLive do
  @moduledoc """
  Admin workspace management (owner-only). Create/delete workspaces, toggle
  default, set visibility (public/private), toggle page types (disabled_page_types),
  and link to the per-workspace settings page at /:ws/settings.
  """

  use DranWeb, :live_view

  import DranWeb.Admin

  alias Dran.Slug
  alias DranWeb.Plugs.Auth

  @impl true
  def mount(_params, session, socket) do
    {socket, _context} = Auth.assign_to_socket(socket, session)

    socket =
      socket
      |> assign(active_nav: "admin", page_title: gettext("Workspaces"), workspace_slug: nil)
      |> assign_workspaces()
      |> assign_users()
      |> assign_workspace_form()
      |> assign(
        slug_touched: false,
        show_workspace_modal: false,
        editing_workspace: nil,
        form_modal_title: gettext("Nuevo contexto"),
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
      workspace_form: to_form(Dran.Workspace.changeset(%Dran.Workspace{}, %{}), as: :context)
    )
  end

  @impl true
  def handle_event("new_workspace", _params, socket) do
    {:noreply,
     assign(socket,
       editing_workspace: nil,
       workspace_form: to_form(Dran.Workspace.changeset(%Dran.Workspace{}, %{}), as: :context),
       form_modal_title: gettext("Nuevo contexto"),
       show_workspace_modal: true
     )}
  end

  @impl true
  def handle_event("edit_workspace", %{"id" => id}, socket) do
    ws = Dran.Knowledge.get_workspace!(id)

    {:noreply,
     assign(socket,
       editing_workspace: ws,
       workspace_form: to_form(Dran.Workspace.changeset(ws, %{}), as: :context),
       form_modal_title: gettext("Editar contexto"),
       show_workspace_modal: true
     )}
  end

  @impl true
  def handle_event("close_context_modal", _params, socket) do
    {:noreply, assign(socket, show_workspace_modal: false)}
  end

  @impl true
  def handle_event("validate_context", %{"context" => params, "_target" => target}, socket) do
    name = params["name"] || ""
    slug_touched = socket.assigns[:slug_touched] || false

    slug_touched =
      if target == ["context", "slug"], do: true, else: slug_touched

    params =
      if slug_touched do
        params
      else
        Map.put(params, "slug", Slug.slugify(name))
      end

    form = %Dran.Workspace{} |> Dran.Workspace.changeset(params) |> to_form(as: :context)
    {:noreply, assign(socket, workspace_form: form, slug_touched: slug_touched)}
  end

  @impl true
  def handle_event("save_workspace", %{"context" => params}, socket) do
    attrs = %{
      name: params["name"],
      visibility: params["visibility"],
      is_default: not is_nil(params["is_default"])
    }

    case save_workspace(socket.assigns.editing_workspace, attrs) do
      {:ok, _context} ->
        {:noreply,
         socket
         |> assign_workspaces()
         |> assign_workspace_form()
         |> assign(slug_touched: false, editing_workspace: nil, show_workspace_modal: false)
         |> put_flash(:info, gettext("Workspace guardado"))}

      {:error, changeset} ->
        {:noreply, assign(socket, workspace_form: to_form(changeset, as: :context))}
    end
  end

  @impl true
  def handle_event("delete_workspace", %{"id" => id}, socket) do
    context = Enum.find(socket.assigns.all_workspaces, &(&1.id == id))

    if context do
      case Dran.Knowledge.delete_workspace(context) do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign_workspaces()
           |> put_flash(:info, gettext(~s(Context "%{name}" deleted), name: context.name))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Could not delete context"))}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("manage_context_users", %{"id" => id}, socket) do
    {:noreply, assign(socket, managing_workspace_id: id, workspace_user_search: "")}
  end

  @impl true
  def handle_event("close_context_users", _params, socket) do
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
    context = Dran.Knowledge.get_workspace!(workspace_id)
    disabled = context.disabled_page_types || []

    new_disabled =
      if page_type in disabled do
        List.delete(disabled, page_type)
      else
        disabled ++ [page_type]
      end

    case Dran.Knowledge.update_workspace_settings(context, %{disabled_page_types: new_disabled}) do
      {:ok, _} -> {:noreply, assign_workspaces(socket)}
      {:error, _} -> {:noreply, put_flash(socket, :error, gettext("Could not update page types"))}
    end
  end

  @impl true
  def handle_event("search_context_users", %{"q" => q}, socket) do
    {:noreply, assign(socket, workspace_user_search: q)}
  end

  @impl true
  def handle_event(
        "toggle_context_user",
        %{"workspace_id" => workspace_id, "user_id" => user_id},
        socket
      ) do
    user = Dran.Accounts.get_user!(user_id)
    context = Dran.Knowledge.get_workspace!(workspace_id)

    if Dran.Accounts.user_in_workspace?(user, context) do
      Dran.Accounts.remove_user_from_workspace(user, context)
    else
      Dran.Accounts.add_user_to_workspace(user, context)
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
      workspace_slug={@workspace_slug}
      workspaces={@workspaces}
      active_nav={@active_nav}
    >
      <div class="flex-1 overflow-y-auto">
        <div class="w-full p-6 space-y-6">
          <div class="flex items-center justify-between">
            <div>
              <h1 class="text-title">{gettext("Workspaces")}</h1>
              <p class="text-caption mt-1">
                {gettext("Create contexts and manage context access per user.")}
              </p>
            </div>
            <button phx-click="new_workspace" class="btn btn-primary btn-sm gap-1.5">
              <.icon name="hero-plus" class="size-4" />
              {gettext("Nuevo contexto")}
            </button>
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
                    <th>{gettext("Visibilidad")}</th>
                    <th>{gettext("Miembros")}</th>
                    <th>{gettext("Default")}</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={ctx <- @all_workspaces} id={"ws-#{ctx.id}"}>
                    <td>
                      <div class="font-medium">{ctx.name}</div>
                      <code class="text-xs text-base-content/60">{ctx.slug}</code>
                    </td>
                    <td>
                      <span class={[
                        "badge badge-sm",
                        ctx.visibility == "public" && "badge-success",
                        ctx.visibility != "public" && "badge-warning"
                      ]}>
                        {if ctx.visibility == "public",
                          do: gettext("Public"),
                          else: gettext("Private")}
                      </span>
                    </td>
                    <td>{Enum.count(@users, &Dran.Accounts.user_in_workspace?(&1, ctx))}</td>
                    <td>
                      <span :if={ctx.is_default} class="badge badge-primary badge-sm">
                        {gettext("default")}
                      </span>
                    </td>
                    <td>
                      <div class="flex items-center gap-1 justify-end">
                        <button
                          phx-click="edit_workspace"
                          phx-value-id={ctx.id}
                          class="btn btn-ghost btn-xs p-1"
                          title={gettext("Editar")}
                        >
                          <.icon name="hero-pencil" class="size-4" />
                        </button>
                        <button
                          phx-click="manage_context_users"
                          phx-value-id={ctx.id}
                          class="btn btn-ghost btn-xs gap-1"
                        >
                          <.icon name="hero-users" class="size-3.5" />
                          {gettext("Usuarios")}
                        </button>
                        <button
                          phx-click="manage_page_types"
                          phx-value-id={ctx.id}
                          class="btn btn-ghost btn-xs gap-1"
                        >
                          <.icon name="hero-squares-2x2" class="size-3.5" />
                          {gettext("Tipos")}
                        </button>
                        <.link
                          navigate={"/#{ctx.slug}/settings"}
                          class="btn btn-ghost btn-xs gap-1"
                          title={gettext("Configuración")}
                        >
                          <.icon name="hero-cog-6-tooth" class="size-3.5" />
                          {gettext("Config")}
                        </.link>
                        <button
                          phx-click="delete_workspace"
                          phx-value-id={ctx.id}
                          data-confirm={gettext("¿Eliminar este workspace?")}
                          class="btn btn-ghost btn-xs p-1 text-error"
                          title={gettext("Eliminar")}
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

          <%!-- Add / edit context modal --%>
          <.modal
            id="context-modal"
            show={@show_workspace_modal}
            title={@form_modal_title}
            on_close="close_context_modal"
          >
            <.form
              for={@workspace_form}
              id="context-form"
              phx-change="validate_context"
              phx-submit="save_workspace"
              class="space-y-4"
            >
              <.input
                field={@workspace_form[:name]}
                type="text"
                label={gettext("Nombre")}
                placeholder={gettext("p.ej. Personal")}
                class="w-full"
                autofocus
              />

              <label class="flex items-center gap-2">
                <input
                  type="checkbox"
                  name="context[is_default]"
                  checked={@editing_workspace && @editing_workspace.is_default}
                  class="checkbox checkbox-sm"
                />
                <span class="text-sm">{gettext("Workspace por defecto")}</span>
              </label>

              <div>
                <label class="text-sm font-medium">{gettext("Visibilidad")}</label>
                <select
                  name="context[visibility]"
                  class="select select-bordered select-sm w-full mt-1"
                >
                  <option
                    value="public"
                    selected={@editing_workspace == nil || @editing_workspace.visibility == "public"}
                  >
                    {gettext("Public")}
                  </option>
                  <option
                    value="private"
                    selected={@editing_workspace && @editing_workspace.visibility == "private"}
                  >
                    {gettext("Private")}
                  </option>
                </select>
              </div>

              <div class="flex justify-end gap-2 pt-2">
                <button type="button" phx-click="close_context_modal" class="btn btn-ghost btn-sm">
                  {gettext("Cancelar")}
                </button>
                <button
                  type="submit"
                  class="btn btn-primary btn-sm"
                  phx-disable-with={gettext("Guardando…")}
                >
                  {gettext("Guardar")}
                </button>
              </div>
            </.form>
          </.modal>

          <%!-- Page types modal --%>
          <.modal
            id="page-types-modal"
            show={@page_types_workspace_id != nil}
            title={gettext("Page types")}
            on_close="close_page_types"
            max_w="max-w-md"
          >
            <% pt_ctx = Enum.find(@all_workspaces, &(&1.id == @page_types_workspace_id)) %>
            <p class="text-caption mt-1">{if pt_ctx, do: pt_ctx.name, else: ""}</p>

            <p class="text-caption mt-1">
              {gettext(
                "Disabled types are hidden in the web UI and rejected in the MCP API for this context."
              )}
            </p>

            <div class="divide-y divide-base-300 mt-2">
              <label
                :for={page_type <- Dran.Knowledge.page_types()}
                class="flex items-center justify-between gap-3 py-2.5 cursor-pointer hover:bg-base-200/50 px-2 rounded-lg transition-colors"
              >
                <div class="min-w-0">
                  <p class="text-sm font-medium">{String.capitalize(page_type)}</p>
                  <p
                    :if={pt_ctx && page_type in (pt_ctx.disabled_page_types || [])}
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
                  checked={pt_ctx && page_type not in (pt_ctx.disabled_page_types || [])}
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
            id="context-users-modal"
            show={@managing_workspace_id != nil}
            title={gettext("Users")}
            on_close="close_context_users"
            max_w="max-w-md"
          >
            <% managing_ctx = Enum.find(@all_workspaces, &(&1.id == @managing_workspace_id)) %>
            <p class="text-caption mt-1">{if managing_ctx, do: managing_ctx.name, else: ""}</p>

            <form phx-change="search_context_users" class="relative mt-3">
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
                  checked={managing_ctx && Dran.Accounts.user_in_workspace?(user, managing_ctx)}
                  phx-click="toggle_context_user"
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
  defp page_type_impact("note"), do: gettext("Notes, notes list")
  defp page_type_impact("concept"), do: gettext("Concepts, concepts list")
  defp page_type_impact("entity"), do: gettext("Entities, entities list")
  defp page_type_impact("reference"), do: gettext("References, references list")
  defp page_type_impact(_), do: ""

  defp save_workspace(nil, attrs) do
    attrs = Map.put_new(attrs, :slug, Slug.slugify(attrs[:name] || ""))
    Dran.Knowledge.create_workspace(attrs)
  end

  defp save_workspace(ws, attrs), do: Dran.Knowledge.update_workspace(ws, attrs)
end
