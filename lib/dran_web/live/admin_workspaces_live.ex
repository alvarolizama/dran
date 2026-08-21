defmodule DranWeb.AdminWorkspacesLive do
  @moduledoc """
  Admin workspace management (owner-only). Create/delete workspaces, toggle
  default, set visibility (public/private), toggle page types (disabled_page_types),
  and link to the per-workspace settings page at /:ws/settings.
  """

  use DranWeb, :live_view

  alias Dran.Slug
  alias DranWeb.Plugs.Auth

  @impl true
  def mount(_params, session, socket) do
    {socket, _context} = Auth.assign_to_socket(socket, session)

    socket =
      socket
      |> assign(active_nav: "admin", page_title: gettext("Workspaces"))
      |> assign_workspaces()
      |> assign_users()
      |> assign_new_workspace_form()
      |> assign(
        confirm_delete_workspace_id: nil,
        slug_touched: false,
        show_workspace_modal: false,
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

  defp assign_new_workspace_form(socket) do
    assign(socket,
      new_workspace_form: to_form(Dran.Workspace.changeset(%Dran.Workspace{}, %{}), as: :context)
    )
  end

  @impl true
  def handle_event("open_context_modal", _params, socket) do
    {:noreply, assign(socket, show_workspace_modal: true)}
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
    {:noreply, assign(socket, new_workspace_form: form, slug_touched: slug_touched)}
  end

  @impl true
  def handle_event("create_workspace", %{"context" => params}, socket) do
    params =
      if is_nil(params["slug"]) or params["slug"] == "" do
        Map.put(params, "slug", Slug.slugify(params["name"] || ""))
      else
        params
      end

    case Dran.Knowledge.create_workspace(params) do
      {:ok, _context} ->
        {:noreply,
         socket
         |> assign_workspaces()
         |> assign_new_workspace_form()
         |> assign(slug_touched: false)
         |> assign(show_workspace_modal: false)
         |> put_flash(:info, gettext("Context created"))}

      {:error, changeset} ->
        {:noreply, assign(socket, new_workspace_form: to_form(changeset, as: :context))}
    end
  end

  @impl true
  def handle_event("ask_delete_workspace", %{"id" => id}, socket) do
    {:noreply, assign(socket, confirm_delete_workspace_id: id)}
  end

  @impl true
  def handle_event("cancel_delete_workspace", _params, socket) do
    {:noreply, assign(socket, confirm_delete_workspace_id: nil)}
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
           |> assign(confirm_delete_workspace_id: nil)
           |> put_flash(:info, gettext("Context \"%{name}\" deleted", name: context.name))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Could not delete context"))}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_is_default", %{"id" => id}, socket) do
    context = Dran.Knowledge.get_workspace!(id)
    new_value = !context.is_default

    case Dran.Knowledge.update_workspace_settings(context, %{is_default: new_value}) do
      {:ok, _} ->
        msg =
          if new_value,
            do: gettext("Default workspace updated"),
            else: gettext("Default workspace removed")

        {:noreply, socket |> assign_workspaces() |> put_flash(:info, msg)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not update default workspace"))}
    end
  end

  @impl true
  def handle_event("toggle_visibility", %{"id" => id}, socket) do
    context = Dran.Knowledge.get_workspace!(id)
    new_visibility = if context.visibility == "public", do: "private", else: "public"

    case Dran.Knowledge.update_workspace_settings(context, %{visibility: new_visibility}) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign_workspaces()
         |> put_flash(
           :info,
           gettext("Visibility set to %{visibility}", visibility: new_visibility)
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not update visibility"))}
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
              <p class="text-caption mt-0.5">
                {gettext("Create contexts and manage context access per user.")}
              </p>
            </div>
            <button
              phx-click="open_context_modal"
              class="btn btn-primary btn-sm gap-1.5"
            >
              <.icon name="hero-plus" class="size-4" />
              {gettext("New context")}
            </button>
          </div>

          <%!-- Context list --%>
          <div class="space-y-4">
            <div
              :for={ctx <- @all_workspaces}
              class={[
                "card bg-base-100 border border-base-300",
                @confirm_delete_workspace_id == ctx.id && "ring-2 ring-error/60 bg-error/5"
              ]}
            >
              <div class="card-body">
                <div class="flex items-start justify-between gap-4">
                  <div class="min-w-0 flex-1">
                    <h3 class="text-lg font-semibold flex items-center gap-2">
                      <span>{ctx.name}</span>
                      <code class="text-sm text-base-content/60">({ctx.slug})</code>
                      <span :if={ctx.is_default} class="badge badge-primary badge-sm">
                        {gettext("default")}
                      </span>
                    </h3>
                    <div class="flex flex-wrap items-center gap-3 mt-1 text-xs text-base-content/50">
                      <span>
                        {if ctx.visibility == "public",
                          do: gettext("Public"),
                          else: gettext("Private")}
                      </span>
                      <span>
                        {ngettext(
                          "%{count} member",
                          "%{count} members",
                          Enum.count(@users, &Dran.Accounts.user_in_workspace?(&1, ctx))
                        )}
                      </span>
                    </div>
                  </div>

                  <div class="flex items-center gap-1.5 shrink-0 flex-wrap justify-end">
                    <button
                      type="button"
                      phx-click="toggle_is_default"
                      phx-value-id={ctx.id}
                      class={[
                        "btn btn-xs gap-1",
                        ctx.is_default && "btn-primary",
                        !ctx.is_default && "btn-ghost"
                      ]}
                      title={gettext("Toggle default")}
                    >
                      <.icon name="hero-star" class="size-3.5" />
                      {gettext("Default")}
                    </button>

                    <button
                      type="button"
                      phx-click="toggle_visibility"
                      phx-value-id={ctx.id}
                      class={[
                        "btn btn-xs gap-1",
                        ctx.visibility == "public" && "btn-success",
                        ctx.visibility != "public" && "btn-warning"
                      ]}
                      title={gettext("Toggle public/private")}
                    >
                      <.icon
                        name={
                          if ctx.visibility == "public",
                            do: "hero-globe-alt",
                            else: "hero-lock-closed"
                        }
                        class="size-3.5"
                      />
                      {if ctx.visibility == "public", do: gettext("Public"), else: gettext("Private")}
                    </button>

                    <button
                      type="button"
                      phx-click="manage_context_users"
                      phx-value-id={ctx.id}
                      class="btn btn-ghost btn-xs gap-1"
                    >
                      <.icon name="hero-users" class="size-3.5" />
                      {gettext("Users")}
                    </button>

                    <button
                      type="button"
                      phx-click="manage_page_types"
                      phx-value-id={ctx.id}
                      class="btn btn-ghost btn-xs gap-1"
                    >
                      <.icon name="hero-squares-2x2" class="size-3.5" />
                      {gettext("Types")}
                    </button>

                    <.link
                      navigate={"/#{ctx.slug}/settings"}
                      class="btn btn-ghost btn-xs gap-1"
                      title={gettext("Workspace settings")}
                    >
                      <.icon name="hero-cog-6-tooth" class="size-3.5" />
                      {gettext("Config")}
                    </.link>

                    <%= if @confirm_delete_workspace_id == ctx.id do %>
                      <span class="text-caption text-error mr-1 hidden sm:inline">
                        {gettext("Delete?")}
                      </span>
                      <button
                        type="button"
                        phx-click="delete_workspace"
                        phx-value-id={ctx.id}
                        class="btn btn-error btn-xs"
                      >
                        <.icon name="hero-check" class="size-3.5" />
                      </button>
                      <button
                        type="button"
                        phx-click="cancel_delete_workspace"
                        class="btn btn-ghost btn-xs"
                      >
                        {gettext("Cancel")}
                      </button>
                    <% else %>
                      <button
                        type="button"
                        phx-click="ask_delete_workspace"
                        phx-value-id={ctx.id}
                        class="btn btn-ghost btn-xs text-error hover:bg-error/10"
                        title={gettext("Delete context")}
                      >
                        <.icon name="hero-trash" class="size-3.5" />
                      </button>
                    <% end %>
                  </div>
                </div>
              </div>
            </div>
          </div>

          <%!-- New context modal --%>
          <div
            :if={@show_workspace_modal}
            class="fixed inset-0 z-50 flex items-center justify-center bg-black/50"
          >
            <div
              class="card bg-base-100 border border-base-300 shadow-xl w-full max-w-lg"
              phx-click-away="close_context_modal"
            >
              <div class="card-body">
                <div class="flex items-center justify-between mb-2">
                  <h3 class="text-lg font-semibold">{gettext("New context")}</h3>
                  <button
                    phx-click="close_context_modal"
                    class="btn btn-ghost btn-xs btn-circle"
                  >
                    <.icon name="hero-x-mark" class="size-4" />
                  </button>
                </div>

                <.form
                  for={@new_workspace_form}
                  id="context-form"
                  phx-change="validate_context"
                  phx-submit="create_workspace"
                  class="space-y-4"
                >
                  <.input
                    field={@new_workspace_form[:name]}
                    type="text"
                    label={gettext("Name")}
                    placeholder={gettext("e.g. Personal")}
                    class="w-full"
                    autofocus
                  />

                  <div class="flex justify-end gap-2 pt-1">
                    <button
                      type="button"
                      phx-click="close_context_modal"
                      class="btn btn-ghost btn-sm"
                    >
                      {gettext("Cancel")}
                    </button>
                    <button
                      type="submit"
                      class="btn btn-primary btn-sm transition-colors active:scale-95"
                      phx-disable-with={gettext("Creating…")}
                    >
                      <.icon name="hero-plus" class="size-4" />
                      {gettext("Create")}
                    </button>
                  </div>
                </.form>
              </div>
            </div>
          </div>

          <%!-- Page types modal --%>
          <div
            :if={@page_types_workspace_id}
            class="fixed inset-0 z-50 flex items-center justify-center bg-black/50"
          >
            <div
              class="card bg-base-100 w-full max-w-md shadow-xl border border-base-300"
              phx-click-away="close_page_types"
            >
              <div class="card-body">
                <% pt_ctx = Enum.find(@all_workspaces, &(&1.id == @page_types_workspace_id)) %>
                <div class="flex items-start justify-between">
                  <div>
                    <h3 class="text-lg font-semibold">
                      {gettext("Page types")}
                    </h3>
                    <p class="text-caption mt-0.5">
                      {if pt_ctx, do: pt_ctx.name, else: ""}
                    </p>
                  </div>
                  <button
                    type="button"
                    phx-click="close_page_types"
                    class="btn btn-ghost btn-xs btn-circle"
                  >
                    <.icon name="hero-x-mark" class="size-4" />
                  </button>
                </div>

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
              </div>
            </div>
          </div>

          <%!-- Manage users modal --%>
          <div
            :if={@managing_workspace_id}
            class="fixed inset-0 z-50 flex items-center justify-center bg-black/50"
          >
            <div
              class="card bg-base-100 w-full max-w-md shadow-xl border border-base-300"
              phx-click-away="close_context_users"
            >
              <div class="card-body">
                <% managing_ctx = Enum.find(@all_workspaces, &(&1.id == @managing_workspace_id)) %>
                <div class="flex items-start justify-between">
                  <div>
                    <h3 class="text-lg font-semibold">
                      {gettext("Users")}
                    </h3>
                    <p class="text-caption mt-0.5">
                      {if managing_ctx, do: managing_ctx.name, else: ""}
                    </p>
                  </div>
                  <button
                    type="button"
                    phx-click="close_context_users"
                    class="btn btn-ghost btn-xs btn-circle"
                  >
                    <.icon name="hero-x-mark" class="size-4" />
                  </button>
                </div>

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
                      class="checkbox checkbox-sm checkbox-primary"
                    />
                  </label>

                  <p :if={filtered_users == []} class="text-caption py-4 text-center">
                    {if @users == [],
                      do: gettext("No users yet — create one in the Users section."),
                      else: gettext("No users match your search.")}
                  </p>
                </div>
              </div>
            </div>
          </div>
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
end
