defmodule DranWeb.WorkspaceSettingsLive do
  @moduledoc """
  Workspace configuration page with tabbed settings: General (name,
  visibility), Page types, Features, Brain tuning, and Users (workspace
  membership).

  Access is enforced by the `:workspace_admin` router pipeline (owner/admin
  of the workspace ∪ instance owner) plus an `attach_hook` defense-in-depth
  that halts every event for non-owners/admins.

  The workspace is resolved from the URL slug (`params["workspace_slug"]`),
  NOT from the session — a user in session workspace "personal" navigating to
  `/work/settings` edits "work" (corrección #10). The role guard also computes
  the role from the URL slug's workspace (corrección #11).
  """

  use DranWeb, :live_view

  import Ecto.Query

  alias Dran.Accounts
  alias Dran.Accounts.UserWorkspace
  alias Dran.Knowledge
  alias Dran.Repo
  alias Dran.Workspace
  alias DranWeb.Plugs.Auth

  # Ordered feature keys shown in the Features tab. All are stored in the
  # `enabled_features` map; an empty map means "all on" (see
  # `Workspace.feature_enabled?/2`).
  @features ~w(goals collections clusters kanban graph journey activity search reports chat workers)

  # Brain tuning keys: worker limits + advanced semantic thresholds.
  @brain_keys ~w(worker_max_pages entity_linker_enabled)
  @advanced_keys ~w(semantic_threshold_short semantic_threshold_mid semantic_threshold_long)

  @impl true
  def mount(%{"workspace_slug" => slug} = _params, session, socket) do
    {socket, _context} = Auth.assign_to_socket(socket, session)

    # Corrección #10: resolve the workspace from the URL slug, not the
    # session. `assign_to_socket` loads the session workspace; we override it
    # with the workspace behind the URL.
    user = Accounts.get_user_by_email(socket.assigns.current_user)
    workspace = Knowledge.get_workspace_by_slug(slug)

    role =
      cond do
        user && user.is_owner -> "owner"
        user && workspace -> Accounts.user_role_in_workspace(user, workspace)
        true -> nil
      end

    socket =
      socket
      |> assign(
        active_nav: "workspace_settings",
        page_title: gettext("Workspace settings"),
        current_user_struct: user,
        workspace: workspace,
        workspace_slug: slug,
        workspace_role: role,
        features: @features,
        active_tab: :general,
        user_search: "",
        workspace_members: [],
        all_users: []
      )
      |> assign_settings_form()
      |> assign_general_form()
      |> assign_workspace_members()
      |> assign_all_users()
      # Corrección #11: defense-in-depth — halt every event for users who are
      # not owner/admin of the URL workspace.
      |> attach_hook(:require_workspace_admin, :handle_event, fn _event, _params, socket ->
        if workspace_admin?(socket) do
          {:cont, socket}
        else
          {:halt, put_flash(socket, :error, gettext("No autorizado."))}
        end
      end)

    {:ok, socket}
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
          <%!-- Page header --%>
          <div>
            <h1 class="text-title">{gettext("Workspace settings")}</h1>
            <p class="text-caption mt-1">
              {if @workspace,
                do: @workspace.name,
                else: gettext("No workspace")}
            </p>
          </div>

          <div :if={is_nil(@workspace)} class="alert alert-warning">
            <.icon name="hero-exclamation-triangle" class="size-5" />
            <span>{gettext("Workspace not found.")}</span>
          </div>

          <div :if={@workspace} class="space-y-6">
            <%!-- Tab navigation --%>
            <div class="flex items-center gap-1 border-b border-base-300 overflow-x-auto">
              <.tab_button active={@active_tab == :general} tab="general" icon="hero-cog-6-tooth">
                {gettext("General")}
              </.tab_button>
              <.tab_button
                active={@active_tab == :page_types}
                tab="page_types"
                icon="hero-document-text"
              >
                {gettext("Page types")}
              </.tab_button>
              <.tab_button active={@active_tab == :features} tab="features" icon="hero-puzzle-piece">
                {gettext("Features")}
              </.tab_button>
              <.tab_button
                active={@active_tab == :brain_tuning}
                tab="brain_tuning"
                icon="hero-adjustments-horizontal"
              >
                {gettext("Brain tuning")}
              </.tab_button>
              <.tab_button active={@active_tab == :users} tab="users" icon="hero-users">
                {gettext("Users")}
              </.tab_button>
            </div>

            <%!-- Tab content --%>
            <div :if={@active_tab == :general}>
              <.general_section workspace={@workspace} form={@general_form} />
            </div>

            <div :if={@active_tab == :page_types}>
              <.page_types_section workspace={@workspace} />
            </div>

            <div :if={@active_tab == :features}>
              <.features_section
                workspace={@workspace}
                form={@settings_form}
                features={@features}
              />
            </div>

            <div :if={@active_tab == :brain_tuning}>
              <.brain_tuning_section workspace={@workspace} form={@settings_form} />
            </div>

            <div :if={@active_tab == :users}>
              <.users_section
                workspace={@workspace}
                members={@workspace_members}
                all_users={@all_users}
                user_search={@user_search}
              />
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # -- Event handlers ---------------------------------------------------------

  @impl true
  def handle_event("select_tab", %{"tab" => tab}, socket) do
    tab_atom = String.to_existing_atom(tab)
    {:noreply, assign(socket, active_tab: tab_atom)}
  end

  @impl true
  def handle_event("save_general", %{"workspace" => params}, socket) do
    workspace = socket.assigns.workspace

    attrs = %{
      "name" => params["name"],
      "visibility" => params["visibility"],
      "is_default" => params["is_default"] == "true"
    }

    case workspace |> Workspace.changeset(attrs) |> Repo.update() do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(workspace: updated)
         |> assign_general_form()
         |> put_flash(:info, gettext("Workspace saved"))}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(general_form: to_form(changeset, as: :workspace))
         |> put_flash(:error, gettext("Could not save workspace"))}
    end
  end

  @impl true
  def handle_event("toggle_page_type", %{"page_type" => page_type}, socket) do
    workspace = socket.assigns.workspace
    disabled = workspace.disabled_page_types || []

    new_disabled =
      if page_type in disabled do
        List.delete(disabled, page_type)
      else
        disabled ++ [page_type]
      end

    case Knowledge.update_workspace_settings(workspace, %{disabled_page_types: new_disabled}) do
      {:ok, updated} ->
        {:noreply, assign(socket, workspace: updated)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not update page types"))}
    end
  end

  @impl true
  def handle_event("save", params, socket) do
    workspace = socket.assigns.workspace

    attrs =
      params
      |> brain_attrs()
      |> Map.put("enabled_features", features_attrs(params))

    case workspace |> Workspace.settings_changeset(attrs) |> Repo.update() do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(workspace: updated)
         |> assign_settings_form()
         |> put_flash(:info, gettext("Settings saved"))}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(settings_form: to_form(changeset, as: :workspace))
         |> put_flash(:error, gettext("Could not save settings"))}
    end
  end

  @impl true
  def handle_event("search_users", %{"q" => q}, socket) do
    {:noreply, assign(socket, user_search: q)}
  end

  @impl true
  def handle_event("toggle_member", %{"user_id" => user_id}, socket) do
    workspace = socket.assigns.workspace
    user = Accounts.get_user!(user_id)

    if Accounts.user_in_workspace?(user, workspace) do
      Accounts.remove_user_from_workspace(user, workspace)
    else
      Accounts.add_user_to_workspace(user, workspace)
    end

    {:noreply,
     socket
     |> assign_workspace_members()
     |> assign_all_users()
     |> put_flash(:info, gettext("Membership updated"))}
  end

  @impl true
  def handle_event("set_member_role", %{"user_id" => user_id, "role" => role}, socket) do
    workspace = socket.assigns.workspace
    user = Accounts.get_user!(user_id)

    case Accounts.update_member_role(user, workspace, role) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign_workspace_members()
         |> assign_all_users()
         |> put_flash(:info, gettext("Role updated"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not update role"))}
    end
  end

  # -- View components --------------------------------------------------------

  attr :active, :boolean, default: false
  attr :tab, :string, required: true
  attr :icon, :string, required: true
  slot :inner_block, required: true

  defp tab_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="select_tab"
      phx-value-tab={@tab}
      class={[
        "flex items-center gap-1.5 px-4 py-2 text-sm font-medium border-b-2 -mb-px transition-colors duration-150 whitespace-nowrap",
        @active && "border-primary text-primary",
        !@active && "border-transparent text-base-content/60 hover:text-base-content"
      ]}
    >
      <.icon name={@icon} class="size-4" />
      {render_slot(@inner_block)}
    </button>
    """
  end

  attr :workspace, Workspace, required: true
  attr :form, :any, required: true

  defp general_section(assigns) do
    ~H"""
    <section class="surface-2 rounded-2xl overflow-hidden">
      <header class="flex items-start gap-3 px-5 py-4 border-b border-base-content/10">
        <div class="shrink-0 size-8 rounded-lg flex items-center justify-center bg-primary/10">
          <.icon name="hero-cog-6-tooth" class="size-4 text-primary" />
        </div>
        <div class="min-w-0">
          <h2 class="text-heading">{gettext("General")}</h2>
          <p class="text-caption mt-1">
            {gettext("Workspace name, visibility, and default status.")}
          </p>
        </div>
      </header>

      <div class="px-5 py-5">
        <.form for={@form} id="workspace-general-form" phx-submit="save_general" class="space-y-4">
          <.input
            field={@form[:name]}
            type="text"
            label={gettext("Name")}
            placeholder={gettext("p.ej. Personal")}
            class="w-full"
          />

          <div>
            <label class="text-sm font-medium">{gettext("Visibility")}</label>
            <select
              name="workspace[visibility]"
              class="select select-bordered select-sm w-full mt-1"
            >
              <option value="public" selected={@workspace.visibility == "public"}>
                {gettext("Public")}
              </option>
              <option value="private" selected={@workspace.visibility == "private"}>
                {gettext("Private")}
              </option>
            </select>
          </div>

          <label class="flex items-center gap-2">
            <input
              type="checkbox"
              name="workspace[is_default]"
              value="true"
              checked={@workspace.is_default}
              class="checkbox checkbox-sm"
            />
            <span class="text-sm">{gettext("Default workspace (forces public visibility)")}</span>
          </label>

          <div class="flex justify-end pt-3 border-t border-base-content/10">
            <button
              type="submit"
              class="btn btn-primary btn-sm transition-colors active:scale-95"
              phx-disable-with={gettext("Saving…")}
            >
              <.icon name="hero-check" class="size-4" />
              {gettext("Save")}
            </button>
          </div>
        </.form>
      </div>
    </section>
    """
  end

  attr :workspace, Workspace, required: true

  defp page_types_section(assigns) do
    ~H"""
    <section class="surface-2 rounded-2xl overflow-hidden">
      <header class="flex items-start gap-3 px-5 py-4 border-b border-base-content/10">
        <div class="shrink-0 size-8 rounded-lg flex items-center justify-center bg-primary/10">
          <.icon name="hero-document-text" class="size-4 text-primary" />
        </div>
        <div class="min-w-0">
          <h2 class="text-heading">{gettext("Page types")}</h2>
          <p class="text-caption mt-1">
            {gettext("Toggle which page types can be created in this workspace.")}
          </p>
        </div>
      </header>

      <div class="px-5 py-5 space-y-3">
        <%= for type <- Dran.Page.all_types() do %>
          <div class="flex items-center justify-between gap-4">
            <div>
              <div class="text-sm font-medium">{page_type_label(type)}</div>
              <div class="text-xs text-base-content/60">{page_type_impact(type)}</div>
            </div>
            <input
              type="checkbox"
              id={"page-type-#{type}"}
              checked={type not in (@workspace.disabled_page_types || [])}
              phx-click="toggle_page_type"
              phx-value-page_type={type}
              class="toggle toggle-sm toggle-primary"
            />
          </div>
        <% end %>
      </div>
    </section>
    """
  end

  attr :workspace, Workspace, required: true
  attr :form, :any, required: true
  attr :features, :list, default: []

  defp features_section(assigns) do
    ~H"""
    <section class="surface-2 rounded-2xl overflow-hidden">
      <header class="flex items-start gap-3 px-5 py-4 border-b border-base-content/10">
        <div class="shrink-0 size-8 rounded-lg flex items-center justify-center bg-accent/10">
          <.icon name="hero-puzzle-piece" class="size-4 text-accent" />
        </div>
        <div class="min-w-0">
          <h2 class="text-heading">{gettext("Features")}</h2>
          <p class="text-caption mt-1">
            {gettext(
              "Enable or disable workspace features. Disabled features hide their entry points."
            )}
          </p>
        </div>
      </header>

      <div class="px-5 py-5">
        <.form for={@form} id="workspace-features-form" phx-submit="save" class="space-y-6">
          <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3">
            <%= for feature <- @features do %>
              <label class="flex items-center gap-3 rounded-xl border border-base-content/10 px-3 py-2.5 cursor-pointer hover:bg-base-200/50 transition-colors">
                <input
                  type="checkbox"
                  name={"enabled_features[#{feature}]"}
                  value="true"
                  checked={Workspace.feature_enabled?(@workspace, feature)}
                  class="checkbox checkbox-sm checkbox-primary"
                />
                <span class="text-sm">{feature_label(feature)}</span>
              </label>
            <% end %>
          </div>

          <div class="flex justify-end pt-3 border-t border-base-content/10">
            <button
              type="submit"
              class="btn btn-primary btn-sm transition-colors active:scale-95"
              phx-disable-with={gettext("Saving…")}
            >
              <.icon name="hero-check" class="size-4" />
              {gettext("Save")}
            </button>
          </div>
        </.form>
      </div>
    </section>
    """
  end

  attr :workspace, Workspace, required: true
  attr :form, :any, required: true

  defp brain_tuning_section(assigns) do
    ~H"""
    <section class="surface-2 rounded-2xl overflow-hidden">
      <header class="flex items-start gap-3 px-5 py-4 border-b border-base-content/10">
        <div class="shrink-0 size-8 rounded-lg flex items-center justify-center bg-secondary/10">
          <.icon name="hero-adjustments-horizontal" class="size-4 text-secondary" />
        </div>
        <div class="min-w-0">
          <h2 class="text-heading">{gettext("Brain tuning")}</h2>
          <p class="text-caption mt-1">
            {gettext("Semantic thresholds and worker limits for this workspace.")}
          </p>
        </div>
      </header>

      <div class="px-5 py-5">
        <.form
          for={@form}
          id="workspace-settings-form"
          phx-submit="save"
          class="space-y-6"
        >
          <%!-- Worker limits --%>
          <div class="space-y-2">
            <h3 class="text-caption font-semibold text-base-content/60 uppercase tracking-wider">
              {gettext("Worker limits")}
            </h3>
            <div class="space-y-4">
              <div>
                <.input
                  field={@form[:worker_max_pages]}
                  type="number"
                  label={gettext("Max pages per run")}
                />
                <p class="text-xs text-base-content/60 mt-1.5">
                  {gettext(
                    "Maximum number of pages the autonomous workers will create in a single run. Blank uses the global default."
                  )}
                </p>
              </div>
              <div>
                <.input
                  field={@form[:entity_linker_enabled]}
                  type="checkbox"
                  label={gettext("Entity linker (auto-create entities from page mentions)")}
                />
                <p class="text-xs text-base-content/60 mt-1.5">
                  {gettext(
                    "When enabled, the augmenter auto-creates entity pages for named things mentioned in page bodies."
                  )}
                </p>
              </div>
            </div>
          </div>

          <%!-- Advanced: semantic thresholds --%>
          <details class="group rounded-xl border border-base-content/10 px-4 py-3">
            <summary class="flex items-center gap-2 cursor-pointer select-none">
              <.icon
                name="hero-chevron-right"
                class="size-4 shrink-0 text-base-content/40 transition-transform duration-150 group-open:rotate-90"
              />
              <.icon name="hero-adjustments-horizontal" class="size-4 text-base-content/40" />
              <span class="text-sm font-semibold text-base-content/70">
                {gettext("Avanzado")}
              </span>
            </summary>
            <div class="mt-4 space-y-2">
              <h3 class="text-caption font-semibold text-base-content/60 uppercase tracking-wider">
                {gettext("Semantic thresholds")}
              </h3>
              <div class="grid grid-cols-1 sm:grid-cols-3 gap-4">
                <.input
                  field={@form[:semantic_threshold_short]}
                  type="number"
                  step="0.01"
                  label={gettext("Short")}
                />
                <.input
                  field={@form[:semantic_threshold_mid]}
                  type="number"
                  step="0.01"
                  label={gettext("Mid")}
                />
                <.input
                  field={@form[:semantic_threshold_long]}
                  type="number"
                  step="0.01"
                  label={gettext("Long")}
                />
              </div>
              <p class="text-xs text-base-content/60">
                {gettext(
                  "Minimum cosine similarity (0.0–1.0) required for a semantic relation between pages. Blank uses the global default."
                )}
              </p>
            </div>
          </details>

          <%!-- Save row --%>
          <div class="flex justify-end pt-3 border-t border-base-content/10">
            <button
              type="submit"
              class="btn btn-primary btn-sm transition-colors active:scale-95"
              phx-disable-with={gettext("Saving…")}
            >
              <.icon name="hero-check" class="size-4" />
              {gettext("Save")}
            </button>
          </div>
        </.form>
      </div>
    </section>
    """
  end

  attr :workspace, Workspace, required: true
  attr :members, :list, required: true
  attr :all_users, :list, required: true
  attr :user_search, :string, required: true

  defp users_section(assigns) do
    ~H"""
    <section class="surface-2 rounded-2xl overflow-hidden">
      <header class="flex items-start gap-3 px-5 py-4 border-b border-base-content/10">
        <div class="shrink-0 size-8 rounded-lg flex items-center justify-center bg-primary/10">
          <.icon name="hero-users" class="size-4 text-primary" />
        </div>
        <div class="min-w-0">
          <h2 class="text-heading">{gettext("Users")}</h2>
          <p class="text-caption mt-1">
            {gettext("Manage which instance users have access to this workspace.")}
          </p>
        </div>
      </header>

      <div class="px-5 py-5 space-y-6">
        <%!-- Current members --%>
        <div>
          <h3 class="text-caption font-semibold text-base-content/60 uppercase tracking-wider mb-3">
            {gettext("Members")} ({length(@members)})
          </h3>

          <div :if={@members == []} class="text-sm text-base-content/50 py-4 text-center">
            {gettext("No users have access to this workspace yet.")}
          </div>

          <div :if={@members != []} class="space-y-2">
            <div
              :for={member <- @members}
              class="flex items-center justify-between gap-3 rounded-xl border border-base-content/10 px-3 py-2.5"
            >
              <div class="min-w-0 flex items-center gap-3">
                <div class="size-8 rounded-full bg-base-content/10 flex items-center justify-center text-xs font-semibold">
                  {String.slice(member.name || member.email || "?", 0, 1)}
                </div>
                <div class="min-w-0">
                  <p class="text-sm font-medium truncate">{member.email}</p>
                  <p :if={member.name} class="text-xs text-base-content/60 truncate">{member.name}</p>
                </div>
              </div>

              <div class="flex items-center gap-2">
                <select
                  name={"role-#{member.id}"}
                  class="select select-bordered select-xs"
                  phx-change="set_member_role"
                  phx-value-user_id={member.id}
                >
                  <%= for role <- ~w(owner admin editor viewer) do %>
                    <option value={role} selected={member.role == role}>
                      {String.capitalize(role)}
                    </option>
                  <% end %>
                </select>

                <button
                  type="button"
                  phx-click="toggle_member"
                  phx-value-user_id={member.id}
                  class="btn btn-ghost btn-xs btn-circle text-error"
                  title={gettext("Remove from workspace")}
                >
                  <.icon name="hero-x-mark" class="size-4" />
                </button>
              </div>
            </div>
          </div>
        </div>

        <%!-- Add users --%>
        <div class="border-t border-base-content/10 pt-5">
          <h3 class="text-caption font-semibold text-base-content/60 uppercase tracking-wider mb-3">
            {gettext("Add users")}
          </h3>

          <form phx-change="search_users" class="relative">
            <.icon
              name="hero-magnifying-glass"
              class="absolute left-3 top-2.5 size-4 text-base-content/50"
            />
            <input
              type="text"
              name="q"
              value={@user_search}
              placeholder={gettext("Search users by email or name...")}
              class="w-full pl-9 pr-3 py-2 text-sm rounded-lg border border-base-300 bg-base-100 transition-colors duration-150 focus:outline-none focus:ring-1 focus:ring-primary"
            />
          </form>

          <div class="mt-3 space-y-2">
            <% member_ids = MapSet.new(@members, & &1.id)
            q = String.downcase(@user_search || "")

            filtered =
              @all_users
              |> Enum.filter(fn user ->
                q == "" or
                  String.contains?(String.downcase(user.email), q) or
                  (user.name && String.contains?(String.downcase(user.name), q))
              end)
              |> Enum.reject(&MapSet.member?(member_ids, &1.id))
              |> Enum.take(5) %>

            <div
              :if={filtered == [] and @user_search != ""}
              class="text-sm text-base-content/50 py-3 text-center"
            >
              {gettext("No users match your search.")}
            </div>

            <div
              :for={user <- filtered}
              class="flex items-center justify-between gap-3 rounded-xl border border-base-content/10 px-3 py-2.5"
            >
              <div class="min-w-0 flex items-center gap-3">
                <div class="size-8 rounded-full bg-base-content/10 flex items-center justify-center text-xs font-semibold">
                  {String.slice(user.name || user.email || "?", 0, 1)}
                </div>
                <div class="min-w-0">
                  <p class="text-sm font-medium truncate">{user.email}</p>
                  <p :if={user.name} class="text-xs text-base-content/60 truncate">{user.name}</p>
                </div>
              </div>

              <button
                type="button"
                phx-click="toggle_member"
                phx-value-user_id={user.id}
                class="btn btn-ghost btn-xs gap-1"
              >
                <.icon name="hero-plus" class="size-3.5" />
                {gettext("Add")}
              </button>
            </div>
          </div>
        </div>
      </div>
    </section>
    """
  end

  # -- Helpers ----------------------------------------------------------------

  # True when the current user is owner/admin of the URL workspace (or the
  # instance owner). Used by the attach_hook defense-in-depth.
  defp workspace_admin?(socket) do
    socket.assigns[:is_owner] or socket.assigns[:workspace_role] in ~w(owner admin)
  end

  # Builds the settings form values from the workspace tuning, falling back to
  # the global default via `Workspace.get_tuning/2`.
  defp assign_settings_form(socket) do
    workspace = socket.assigns.workspace

    values =
      Map.new(@brain_keys ++ @advanced_keys, fn key ->
        {key, Workspace.get_tuning(workspace, key)}
      end)

    assign(socket, settings_form: to_form(values, as: :workspace))
  end

  # General tab form: name, visibility, is_default from the workspace itself.
  defp assign_general_form(socket) do
    workspace = socket.assigns.workspace
    changeset = Workspace.changeset(workspace, %{})
    assign(socket, general_form: to_form(changeset, as: :workspace))
  end

  # Loads all users that are members of this workspace, with their role.
  defp assign_workspace_members(socket) do
    workspace = socket.assigns.workspace

    members =
      if workspace do
        UserWorkspace
        |> where([uw], uw.workspace_id == ^workspace.id)
        |> join(:inner, [uw], u in assoc(uw, :user))
        |> order_by([_, u], asc: u.email)
        |> select([uw, u], %{
          id: u.id,
          email: u.email,
          name: u.name,
          role: uw.role
        })
        |> Repo.all()
      else
        []
      end

    assign(socket, workspace_members: members)
  end

  # Loads all instance users for the "Add users" search list.
  defp assign_all_users(socket) do
    assign(socket, all_users: Accounts.list_users())
  end

  # Normalizes the brain tuning params: blank number inputs become nil (so the
  # global default applies) and the entity linker checkbox becomes a real
  # boolean.
  defp brain_attrs(params) do
    ws_params = Map.get(params, "workspace", %{})

    ws_params
    |> Map.update("semantic_threshold_short", nil, &blank_to_nil/1)
    |> Map.update("semantic_threshold_mid", nil, &blank_to_nil/1)
    |> Map.update("semantic_threshold_long", nil, &blank_to_nil/1)
    |> Map.update("worker_max_pages", nil, &blank_to_nil/1)
    |> Map.put("entity_linker_enabled", Map.get(ws_params, "entity_linker_enabled") == "true")
  end

  # Rebuilds the full enabled_features map with real booleans. Unchecked
  # checkboxes are absent from the params, so every feature is set explicitly.
  defp features_attrs(params) do
    raw = Map.get(params, "enabled_features", %{})

    Map.new(@features, fn feature ->
      {feature, Map.get(raw, feature) == "true"}
    end)
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp page_type_label("note"), do: gettext("Note")
  defp page_type_label("concept"), do: gettext("Concept")
  defp page_type_label("entity"), do: gettext("Entity")
  defp page_type_label("reference"), do: gettext("Reference")
  defp page_type_label(other), do: other

  defp page_type_impact("note"), do: gettext("Notes, notes list")
  defp page_type_impact("concept"), do: gettext("Concepts, concepts list")
  defp page_type_impact("entity"), do: gettext("Entities, entities list")
  defp page_type_impact("reference"), do: gettext("References, references list")
  defp page_type_impact(_), do: ""

  defp feature_label("goals"), do: gettext("Goals")
  defp feature_label("collections"), do: gettext("Collections")
  defp feature_label("clusters"), do: gettext("Clusters")
  defp feature_label("kanban"), do: gettext("Kanban")
  defp feature_label("graph"), do: gettext("Graph")
  defp feature_label("journey"), do: gettext("Journey")
  defp feature_label("activity"), do: gettext("Activity")
  defp feature_label("search"), do: gettext("Search")
  defp feature_label("reports"), do: gettext("Reports")
  defp feature_label("chat"), do: gettext("Chat")
  defp feature_label("workers"), do: gettext("Workers")
  defp feature_label(other), do: other
end
