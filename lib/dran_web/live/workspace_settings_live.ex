defmodule DranWeb.WorkspaceSettingsLive do
  @moduledoc """
  Workspace configuration page with tabbed settings: General (name, default
  flag), Page types, Features, Automation (worker limits + semantic
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

  # Feature toggles shown in the Features tab, grouped the way a user thinks
  # about them. All are stored in the `enabled_features` map; an empty map means
  # "all on" (see `Workspace.feature_enabled?/2`). Only features with real entry
  # points gated in `Layouts.workspace_groups/3` (sidebar): kanban/chat were
  # removed products and "workers" was a typo for "workflows" (the gated key).
  @feature_groups [
    {"Knowledge base", ~w(search graph journey collections)},
    {"Insights", ~w(clusters reports activity)}
  ]
  @features Enum.flat_map(@feature_groups, fn {_group, keys} -> keys end)

  # Brain tuning keys: worker limits + advanced semantic thresholds.
  @brain_keys ~w(worker_max_pages entity_linker_enabled summary_language)
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
        feature_groups: @feature_groups,
        active_tab: :general,
        user_search: "",
        invite_form: to_form(%{"email" => "", "role" => "viewer"}, as: :invite),
        workspace_members: [],
        all_users: []
      )
      |> assign_settings_form()
      |> assign_general_form()
      |> assign_custom_type_form()
      |> assign_workspace_members()
      |> assign_all_users()
      # Corrección #11: defense-in-depth — halt every event for users who are
      # not owner/admin of the URL workspace.
      |> attach_hook(:require_workspace_admin, :handle_event, fn _event, _params, socket ->
        if workspace_admin?(socket) do
          {:cont, socket}
        else
          {:halt, put_flash(socket, :error, gettext("Not authorized."))}
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
      user={@user}
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
                {gettext("Automation")}
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
              <.page_types_section
                workspace={@workspace}
                custom_type_form={@custom_type_form}
                custom_type_error={@custom_type_error}
              />
            </div>

            <div :if={@active_tab == :features}>
              <.features_section
                workspace={@workspace}
                form={@settings_form}
                groups={@feature_groups}
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
                invite_form={@invite_form}
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

  # -- Custom page types ------------------------------------------------------
  #
  # The form is validated live (`phx-change`) so the JSON editor can report
  # malformed `meta_fields` before submit. On a domain rejection the submitted
  # values — JSON included — stay in the form: losing what you typed is the
  # fastest way to make a config screen feel hostile.

  @impl true
  def handle_event("validate_custom_page_type", %{"workspace" => params}, socket) do
    # Re-validates on every keystroke and clears the previous server-side
    # error: the message must describe what is in the box right now.
    {:noreply,
     assign(socket, custom_type_form: to_form(params, as: :workspace), custom_type_error: nil)}
  end

  @impl true
  def handle_event("load_meta_fields_example", %{"example" => key}, socket) do
    case Enum.find(meta_field_examples(), fn example -> example.key == key end) do
      nil ->
        {:noreply, socket}

      example ->
        params =
          custom_type_form_params(socket, "meta_fields", example.json)

        {:noreply,
         assign(socket, custom_type_form: to_form(params, as: :workspace), custom_type_error: nil)}
    end
  end

  @impl true
  def handle_event("clear_meta_fields", _params, socket) do
    params = custom_type_form_params(socket, "meta_fields", "")

    {:noreply,
     assign(socket, custom_type_form: to_form(params, as: :workspace), custom_type_error: nil)}
  end

  @impl true
  def handle_event("add_custom_page_type", %{"workspace" => params}, socket) do
    workspace = socket.assigns.workspace

    case parse_meta_fields(params["meta_fields"]) do
      {:error, message} ->
        {:noreply,
         assign(socket,
           custom_type_form: to_form(params, as: :workspace),
           custom_type_error: message
         )}

      {:ok, meta_fields} ->
        entry = %{
          "slug" => params["slug"],
          "label" => params["label"],
          "plural" => params["plural"],
          "path" => params["path"],
          "icon" => params["icon"],
          "color" => params["color"],
          "meta_fields" => meta_fields
        }

        existing = Dran.Workspace.custom_page_types(workspace)

        case Knowledge.update_workspace_settings(workspace, %{
               workspace_page_types: existing ++ [entry]
             }) do
          {:ok, updated} ->
            {:noreply,
             socket
             |> assign(workspace: updated, custom_type_error: nil)
             |> assign_custom_type_form()
             |> put_flash(:info, gettext("Page type added"))}

          {:error, changeset} ->
            # Keep every submitted value (the JSON too) so the user can fix
            # and resubmit instead of retyping the whole definition.
            {:noreply,
             assign(socket,
               custom_type_error: custom_type_message(changeset),
               custom_type_form: to_form(params, as: :workspace)
             )}
        end
    end
  end

  @impl true
  def handle_event("remove_custom_page_type", %{"slug" => slug}, socket) do
    workspace = socket.assigns.workspace

    remaining =
      workspace
      |> Dran.Workspace.custom_page_types()
      |> Enum.reject(&(&1["slug"] == slug))

    case Knowledge.update_workspace_settings(workspace, %{workspace_page_types: remaining}) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(workspace: updated, custom_type_error: nil)
         |> put_flash(:info, gettext("Page type removed"))}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, custom_type_message(changeset))}
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
      |> Map.put("share_memory", share_attr(params, "share_memory"))
      |> Map.put("share_pages", share_attr(params, "share_pages"))

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

  # "Invite" in Dran means: give an EXISTING account access to this workspace.
  # There is no invitation email and no pending-invitation state — the person
  # must already have an account on this instance, and the membership exists as
  # soon as this returns. Hence the explicit not-found message.
  @impl true
  def handle_event("invite_member", %{"invite" => params}, socket) do
    workspace = socket.assigns.workspace
    email = params["email"] || ""
    role = params["role"] || "viewer"

    case Accounts.add_member_by_email(workspace, email, role) do
      {:ok, _membership} ->
        {:noreply,
         socket
         |> assign(invite_form: to_form(%{"email" => "", "role" => role}, as: :invite))
         |> assign_workspace_members()
         |> assign_all_users()
         |> put_flash(:info, gettext("%{email} now has access to this workspace", email: email))}

      {:error, :user_not_found} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext(
             "No account with that email exists on this instance. Only existing users can be added."
           )
         )}

      {:error, :already_member} ->
        {:noreply,
         put_flash(socket, :info, gettext("That user already has access to this workspace."))}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Could not add the user"))}
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
    <section id="general-section" class="surface-2 rounded-2xl overflow-hidden">
      <header class="flex items-start gap-3 px-5 py-4 border-b border-base-content/10">
        <div class="shrink-0 size-8 rounded-lg flex items-center justify-center bg-primary/10">
          <.icon name="hero-cog-6-tooth" class="size-4 text-primary" />
        </div>
        <div class="min-w-0">
          <h2 class="text-heading">{gettext("General")}</h2>
          <p class="text-caption mt-1">
            {gettext("What this workspace is called and who can reach it.")}
          </p>
        </div>
      </header>

      <div class="px-5 py-5">
        <.form for={@form} id="workspace-general-form" phx-submit="save_general" class="space-y-6">
          <%!-- Identity --%>
          <div class="space-y-3">
            <h3 class="text-caption font-semibold text-base-content/60 uppercase tracking-wider">
              {gettext("Identity")}
            </h3>

            <div>
              <.input
                field={@form[:name]}
                type="text"
                label={gettext("Name")}
                placeholder={gettext("e.g. Personal")}
              />
              <p class="text-xs text-base-content/50 mt-1.5">
                {gettext("Shown in the workspace switcher, the sidebar and every breadcrumb.")}
              </p>
            </div>

            <%!-- The slug is the URL identity of the workspace and is not
                 editable here: changing it would break every existing link. --%>
            <div>
              <span class="block text-sm font-medium text-base-content/70 mb-1.5">
                {gettext("Slug")}
              </span>
              <div class="flex items-center gap-2">
                <code class="rounded-lg border border-base-300 bg-base-200/50 px-2 py-1.5 font-mono text-xs">
                  {@workspace.slug}
                </code>
                <span class="text-xs text-base-content/50">{gettext("read-only")}</span>
              </div>
              <p class="text-xs text-base-content/50 mt-1.5">
                {gettext(
                  "The workspace identifier in every URL: /%{slug}/notes, /%{slug}/settings…",
                  slug: @workspace.slug
                )}
              </p>
            </div>
          </div>

          <%!-- Access --%>
          <div class="space-y-3">
            <h3 class="text-caption font-semibold text-base-content/60 uppercase tracking-wider">
              {gettext("Access")}
            </h3>

            <%!-- There is no visibility control any more: every workspace is
                 private and access is granted one account at a time from the
                 Users tab. The old public/private select was removed rather
                 than left disabled, so nothing suggests a discoverable tier
                 that no longer exists. --%>
            <div class="flex items-start gap-3 rounded-xl border border-base-content/10 px-3 py-2.5">
              <.icon name="hero-lock-closed" class="size-4 mt-0.5 shrink-0 text-base-content/50" />
              <div class="min-w-0">
                <span class="block text-sm font-medium text-base-content">
                  {gettext("Private")}
                </span>
                <span class="block text-xs text-base-content/60 mt-1">
                  {gettext(
                    "Only the people you add from the Users tab can open this workspace, and it never appears in anyone else's list. There is no public, discoverable tier."
                  )}
                </span>
              </div>
            </div>

            <div>
              <input type="hidden" name="workspace[is_default]" value="false" />
              <label
                for="workspace-is-default"
                class="flex items-start gap-3 cursor-pointer rounded-xl border border-base-content/10 px-3 py-2.5 transition-colors duration-150 hover:bg-base-200/40"
              >
                <input
                  type="checkbox"
                  id="workspace-is-default"
                  name="workspace[is_default]"
                  value="true"
                  checked={@workspace.is_default}
                  class="mt-0.5 size-4 rounded border-base-300 text-primary focus:ring-1 focus:ring-primary"
                />
                <span class="min-w-0">
                  <span class="block text-sm font-medium text-base-content">
                    {gettext("Default workspace")}
                  </span>
                  <span class="block text-xs text-base-content/60 mt-1">
                    {gettext(
                      "Where an account lands when it has no personal workspace of its own. Only one workspace can be the default."
                    )}
                  </span>
                </span>
              </label>
            </div>
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
  attr :custom_type_form, :any, required: true
  attr :custom_type_error, :any, default: nil

  defp page_types_section(assigns) do
    ~H"""
    <section id="page-types-section" class="surface-2 rounded-2xl overflow-hidden">
      <header class="flex items-start gap-3 px-5 py-4 border-b border-base-content/10">
        <div class="shrink-0 size-8 rounded-lg flex items-center justify-center bg-primary/10">
          <.icon name="hero-document-text" class="size-4 text-primary" />
        </div>
        <div class="min-w-0">
          <h2 class="text-heading">{gettext("Page types")}</h2>
          <p class="text-caption mt-1">
            {gettext("Which kinds of page this workspace can hold, and which of them are enabled.")}
          </p>
        </div>
      </header>

      <%!-- Effective types = 4 built-in ∪ custom; custom ones cannot collide
           with a built-in, so one loop covers both. --%>
      <div class="px-5 py-5">
        <h3 class="text-caption font-semibold text-base-content/60 uppercase tracking-wider mb-3">
          {gettext("Available types")}
        </h3>

        <div class="space-y-2">
          <%= for type <- effective_page_types(@workspace) do %>
            <% custom? = Dran.Workspace.custom_page_type?(@workspace, type)
            enabled? = type not in (@workspace.disabled_page_types || [])
            ui = Dran.Workspace.page_type_ui(@workspace, type) %>
            <div class="flex items-center justify-between gap-4 rounded-xl border border-base-content/10 px-3 py-2.5 transition-colors duration-150 hover:bg-base-200/40">
              <div class="flex items-center gap-3 min-w-0">
                <span class="shrink-0 size-8 rounded-lg flex items-center justify-center bg-base-200/70">
                  <.icon name={ui.icon} class="size-4 text-base-content/70" />
                </span>
                <span class="shrink-0 size-2 rounded-full" style={"background-color: #{ui.color}"}></span>
                <div class="min-w-0">
                  <div class="text-sm font-medium flex items-center gap-2 flex-wrap">
                    {ui.label}
                    <span class="text-xs font-normal text-base-content/40">{ui.plural}</span>
                    <span :if={custom?} class="badge badge-ghost badge-xs">
                      {gettext("custom")}
                    </span>
                  </div>
                  <div class="text-xs text-base-content/50 font-mono truncate">
                    /{ui.path}
                  </div>
                </div>
              </div>

              <div class="flex items-center gap-3 shrink-0">
                <span class={[
                  "text-xs hidden sm:inline",
                  enabled? && "text-success",
                  !enabled? && "text-base-content/40"
                ]}>
                  {if enabled?, do: gettext("Enabled"), else: gettext("Disabled")}
                </span>
                <button
                  :if={custom?}
                  type="button"
                  phx-click="remove_custom_page_type"
                  phx-value-slug={type}
                  data-confirm={
                    gettext(
                      "Remove the “%{label}” page type? Its pages are kept, but they lose their section and list.",
                      label: ui.label
                    )
                  }
                  class="text-xs text-error/80 hover:text-error transition-colors duration-150"
                >
                  {gettext("Remove")}
                </button>
                <input
                  type="checkbox"
                  id={"page-type-#{type}"}
                  checked={enabled?}
                  phx-click="toggle_page_type"
                  phx-value-page_type={type}
                  class="toggle toggle-sm toggle-primary"
                />
              </div>
            </div>
          <% end %>
        </div>
      </div>

      <%!-- Declaring a new type: guided fields for the common case, plus a
           validated JSON editor for the editor `meta_fields`. --%>
      <div class="border-t border-base-content/10 px-5 py-5 space-y-5">
        <div>
          <h3 class="text-sm font-semibold">{gettext("Add a custom page type")}</h3>
          <p class="text-caption mt-1">
            {gettext(
              "Gets its own sidebar section, list, graph colour and editor fields. The four built-in types cannot be redefined."
            )}
          </p>
        </div>

        <.form
          for={@custom_type_form}
          id="custom-page-type-form"
          phx-change="validate_custom_page_type"
          phx-submit="add_custom_page_type"
          phx-debounce="300"
          class="space-y-6"
        >
          <%!-- Computed once, at the top: the URL hint below and the preview
               card both read from it, so they can never disagree. --%>
          <% preview = custom_type_preview(@custom_type_form.params) %>

          <%!-- Identity --%>
          <div class="space-y-3">
            <h4 class="text-caption font-semibold text-base-content/60 uppercase tracking-wider">
              {gettext("Identity")}
            </h4>
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-x-4 gap-y-3">
              <div>
                <.input
                  field={@custom_type_form[:slug]}
                  label={gettext("Slug")}
                  placeholder="recipe"
                />
                <p class="text-xs text-base-content/50 mt-1.5">
                  {gettext(
                    "Identifier used by the API and by filters. Lowercase letters, digits, “_” or “-”."
                  )}
                </p>
              </div>
              <div>
                <.input
                  field={@custom_type_form[:path]}
                  label={gettext("URL path")}
                  placeholder="recipes"
                />
                <p class="text-xs text-base-content/50 mt-1.5">
                  {gettext(
                    "URL segment — pages will live at /workspace/%{path}/slug. Must be unique and cannot collide with a reserved route.",
                    path: preview.path || "recipes"
                  )}
                </p>
              </div>
              <div>
                <.input
                  field={@custom_type_form[:label]}
                  label={gettext("Label")}
                  placeholder="Recipe"
                />
                <p class="text-xs text-base-content/50 mt-1.5">
                  {gettext("Singular name, used in the sidebar and on buttons.")}
                </p>
              </div>
              <div>
                <.input
                  field={@custom_type_form[:plural]}
                  label={gettext("Plural")}
                  placeholder="Recipes"
                />
                <p class="text-xs text-base-content/50 mt-1.5">
                  {gettext("Plural name, used for lists and counters.")}
                </p>
              </div>
            </div>
          </div>

          <%!-- Presentation --%>
          <div class="space-y-3">
            <h4 class="text-caption font-semibold text-base-content/60 uppercase tracking-wider">
              {gettext("Presentation")}
            </h4>
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-x-4 gap-y-3">
              <div>
                <.input
                  field={@custom_type_form[:icon]}
                  label={gettext("Icon")}
                  placeholder="hero-beaker"
                />
                <p class="text-xs text-base-content/50 mt-1.5">
                  {gettext("Heroicons name. The “hero-” prefix is added automatically.")}
                </p>
              </div>
              <div>
                <.input
                  field={@custom_type_form[:color]}
                  label={gettext("Color")}
                  placeholder="#F59E0B"
                />
                <p class="text-xs text-base-content/50 mt-1.5">
                  {gettext("Hex colour for the graph node, the legend and the type dot.")}
                </p>
              </div>
            </div>
          </div>

          <%!-- Live preview of everything above --%>
          <div class="rounded-xl border border-base-content/10 bg-base-200/30 px-4 py-3">
            <p class="text-caption font-semibold text-base-content/50 uppercase tracking-wider mb-2">
              {gettext("Preview")}
            </p>
            <div class="flex items-center gap-3 min-w-0">
              <span class="shrink-0 size-8 rounded-lg flex items-center justify-center bg-base-100">
                <.icon name={preview.icon} class="size-4 text-base-content/70" />
              </span>
              <span class="shrink-0 size-2 rounded-full" style={"background-color: #{preview.color}"}></span>
              <div class="min-w-0">
                <p class="text-sm font-medium">
                  {preview.label}
                  <span class="text-xs font-normal text-base-content/40">{preview.plural}</span>
                </p>
                <p class="text-xs text-base-content/50 font-mono truncate">
                  /{preview.path || "—"} · {preview.slug || "—"}
                </p>
              </div>
            </div>
          </div>

          <%!-- Meta fields: validated JSON editor --%>
          <% feedback = meta_fields_feedback(@custom_type_form[:meta_fields].value) %>
          <div class="space-y-2">
            <div class="flex items-baseline justify-between gap-3">
              <h4 class="text-caption font-semibold text-base-content/60 uppercase tracking-wider">
                {gettext("Meta fields")}
              </h4>
              <span class="text-xs text-base-content/40">{gettext("optional")}</span>
            </div>

            <p class="text-xs text-base-content/60">
              {gettext(
                "Extra fields the editor renders for this type. One JSON array per field: [type, key, label] with type one of %{types}.",
                types: "text, date, props"
              )}
            </p>

            <.input
              field={@custom_type_form[:meta_fields]}
              type="textarea"
              rows="6"
              placeholder={~s([["text", "cuisine", "Cuisine"]])}
              class="w-full rounded-lg border border-base-300 bg-base-100 px-3 py-2 font-mono text-xs leading-relaxed transition-colors duration-150 focus:outline-none focus:ring-1 focus:ring-primary placeholder:text-base-content/30"
            />

            <%= case feedback do %>
              <% {:empty, _} -> %>
                <p class="text-xs text-base-content/50">
                  {gettext("Empty is fine — the type simply gets no extra fields.")}
                </p>
              <% {:ok, fields} -> %>
                <div class="flex flex-wrap items-center gap-1.5">
                  <.icon name="hero-check-circle" class="size-3.5 text-success shrink-0" />
                  <span class="text-xs text-success">
                    {ngettext("%{count} valid field", "%{count} valid fields", length(fields))}
                  </span>
                  <span
                    :for={field <- fields}
                    class="badge badge-ghost badge-sm font-mono text-[10px]"
                  >
                    {meta_field_chip(field)}
                  </span>
                </div>
              <% {:error, message} -> %>
                <p class="flex items-start gap-1.5 text-xs text-error">
                  <.icon name="hero-exclamation-circle" class="size-3.5 mt-px shrink-0" />
                  <span>{message}</span>
                </p>
            <% end %>

            <div class="flex flex-wrap items-center gap-1.5 pt-1">
              <span class="text-xs text-base-content/50">{gettext("Load an example:")}</span>
              <button
                :for={example <- meta_field_examples()}
                type="button"
                phx-click="load_meta_fields_example"
                phx-value-example={example.key}
                class="btn btn-ghost btn-xs"
              >
                {example.label}
              </button>
              <button
                type="button"
                phx-click="clear_meta_fields"
                class="btn btn-ghost btn-xs text-base-content/50"
              >
                {gettext("Clear")}
              </button>
            </div>
          </div>

          <div
            :if={@custom_type_error}
            class="flex items-start gap-2 rounded-xl border border-error/30 bg-error/5 px-3 py-2.5 text-sm text-error"
          >
            <.icon name="hero-exclamation-triangle" class="size-4 mt-0.5 shrink-0" />
            <span>{@custom_type_error}</span>
          </div>

          <div class="flex justify-end pt-3 border-t border-base-content/10">
            <button
              type="submit"
              class="btn btn-sm btn-primary transition-colors active:scale-95"
              phx-disable-with={gettext("Adding…")}
            >
              <.icon name="hero-plus" class="size-4" />
              {gettext("Add page type")}
            </button>
          </div>
        </.form>
      </div>
    </section>
    """
  end

  attr :workspace, Workspace, required: true
  attr :form, :any, required: true
  attr :groups, :list, default: []

  defp features_section(assigns) do
    ~H"""
    <section id="features-section" class="surface-2 rounded-2xl overflow-hidden">
      <header class="flex items-start gap-3 px-5 py-4 border-b border-base-content/10">
        <div class="shrink-0 size-8 rounded-lg flex items-center justify-center bg-accent/10">
          <.icon name="hero-puzzle-piece" class="size-4 text-accent" />
        </div>
        <div class="min-w-0">
          <h2 class="text-heading">{gettext("Features")}</h2>
          <p class="text-caption mt-1">
            {gettext(
              "Turn parts of this workspace on or off. Disabling a feature only removes its entry point — no page, relation or summary is ever deleted."
            )}
          </p>
        </div>
      </header>

      <div class="px-5 py-5">
        <.form for={@form} id="workspace-features-form" phx-submit="save" class="space-y-6">
          <div :for={{group, features} <- @groups} class="space-y-3">
            <h3 class="text-caption font-semibold text-base-content/60 uppercase tracking-wider">
              {group_label(group)}
            </h3>

            <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
              <label
                :for={feature <- features}
                class="flex items-start gap-3 rounded-xl border border-base-content/10 px-3 py-2.5 cursor-pointer transition-colors duration-150 hover:bg-base-200/40"
              >
                <input
                  type="checkbox"
                  id={"feature-#{feature}"}
                  name={"enabled_features[#{feature}]"}
                  value="true"
                  checked={Workspace.feature_enabled?(@workspace, feature)}
                  class="mt-0.5 size-4 rounded border-base-300 text-primary focus:ring-1 focus:ring-primary"
                />
                <span class="min-w-0">
                  <span class="flex items-center gap-2">
                    <span class="text-sm font-medium">{feature_label(feature)}</span>
                    <%!-- Same vocabulary as the Page types list: one state, one
                         word. (A bare "on"/"off" msgid is also a trap: it is
                         already polluted in the catalog by a fuzzy match.) --%>
                    <span class={[
                      "text-[10px] uppercase tracking-wide",
                      Workspace.feature_enabled?(@workspace, feature) && "text-success",
                      !Workspace.feature_enabled?(@workspace, feature) && "text-base-content/40"
                    ]}>
                      {if Workspace.feature_enabled?(@workspace, feature),
                        do: gettext("Enabled"),
                        else: gettext("Disabled")}
                    </span>
                  </span>
                  <span class="block text-xs text-base-content/60 mt-1">
                    {feature_description(feature)}
                  </span>
                </span>
              </label>
            </div>
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
    <section id="automation-section" class="surface-2 rounded-2xl overflow-hidden">
      <header class="flex items-start gap-3 px-5 py-4 border-b border-base-content/10">
        <div class="shrink-0 size-8 rounded-lg flex items-center justify-center bg-secondary/10">
          <.icon name="hero-adjustments-horizontal" class="size-4 text-secondary" />
        </div>
        <div class="min-w-0">
          <h2 class="text-heading">{gettext("Automation")}</h2>
          <p class="text-caption mt-1">
            {gettext(
              "Worker limits, semantic thresholds and summary language for this workspace. Applies to autonomous workers, the page augmenter and the nightly cron jobs."
            )}
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
          <div class="space-y-3">
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
                    "Maximum pages the autonomous workers (GraphRAG, Curator, Link gardener) create in a single run. Blank uses the global default."
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
                    "When enabled, the page augmenter (runs on every page save, via the Relations supervisor) auto-creates entity pages for named things mentioned in page bodies."
                  )}
                </p>
              </div>
              <div>
                <.input
                  field={@form[:summary_language]}
                  type="select"
                  options={summary_language_options()}
                  label={gettext("Summary language")}
                />
                <p class="text-xs text-base-content/60 mt-1.5">
                  {gettext(
                    "Language the assistants write generated summaries and memories in: page summaries (augmenter + nightly backfill job), cluster summaries (nightly job) and agent memories (API ingest). \"Auto\" matches the language of each page or transcript."
                  )}
                </p>
              </div>
            </div>
          </div>

          <%!-- Read sharing policy --%>
          <div class="space-y-3">
            <h3 class="text-caption font-semibold text-base-content/60 uppercase tracking-wider">
              {gettext("Share read access")}
            </h3>
            <div class="space-y-4">
              <div>
                <input
                  type="hidden"
                  name="workspace[share_memory]"
                  value="false"
                />
                <label
                  for="workspace-share-memory"
                  class="flex items-start gap-3 cursor-pointer rounded-xl border border-base-content/10 px-3 py-2.5 transition-colors duration-150 hover:bg-base-200/40"
                >
                  <input
                    id="workspace-share-memory"
                    type="checkbox"
                    name="workspace[share_memory]"
                    value="true"
                    checked={@workspace.share_memory}
                    class="mt-0.5 size-4 rounded border-base-300 text-primary focus:ring-1 focus:ring-primary"
                  />
                  <span class="min-w-0">
                    <span class="block text-sm font-medium text-base-content">
                      {gettext("Share memory between workspace users")}
                    </span>
                    <span class="block text-xs text-base-content/60 mt-1">
                      {gettext(
                        "When disabled, each user (and their agents) only sees the facts that belong to them; workspace owners and admins keep the full view."
                      )}
                    </span>
                  </span>
                </label>
              </div>
              <div>
                <input
                  type="hidden"
                  name="workspace[share_pages]"
                  value="false"
                />
                <label
                  for="workspace-share-pages"
                  class="flex items-start gap-3 cursor-pointer rounded-xl border border-base-content/10 px-3 py-2.5 transition-colors duration-150 hover:bg-base-200/40"
                >
                  <input
                    id="workspace-share-pages"
                    type="checkbox"
                    name="workspace[share_pages]"
                    value="true"
                    checked={@workspace.share_pages}
                    class="mt-0.5 size-4 rounded border-base-300 text-primary focus:ring-1 focus:ring-primary"
                  />
                  <span class="min-w-0">
                    <span class="block text-sm font-medium text-base-content">
                      {gettext("Share pages between workspace users")}
                    </span>
                    <span class="block text-xs text-base-content/60 mt-1">
                      {gettext(
                        "When disabled, each user only sees the pages that belong to them; the graph only draws visible nodes and edges."
                      )}
                    </span>
                  </span>
                </label>
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
                {gettext("Advanced")}
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
                  "Minimum cosine similarity (0.0–1.0) required for a semantic relation between pages. Used by the page augmenter when linking new pages (short/mid/long by body length) and by the nightly graph maintenance cron when pruning weak semantic relations (long). Blank uses the global default."
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
  attr :invite_form, :any, required: true

  defp users_section(assigns) do
    ~H"""
    <section id="users-section" class="surface-2 rounded-2xl overflow-hidden">
      <header class="flex items-start gap-3 px-5 py-4 border-b border-base-content/10">
        <div class="shrink-0 size-8 rounded-lg flex items-center justify-center bg-primary/10">
          <.icon name="hero-users" class="size-4 text-primary" />
        </div>
        <div class="min-w-0">
          <h2 class="text-heading">{gettext("Users")}</h2>
          <p class="text-caption mt-1">
            {gettext("Who can open this workspace, and with which role.")}
          </p>
        </div>
      </header>

      <div class="px-5 py-5 space-y-6">
        <%!-- Current members --%>
        <div>
          <h3 class="text-caption font-semibold text-base-content/60 uppercase tracking-wider mb-1">
            {gettext("Members")} ({length(@members)})
          </h3>

          <%!-- What each role means. Picking a role is a permission decision;
               the select's options are otherwise just four words. --%>
          <ul class="mb-3 space-y-0.5">
            <li :for={role <- ~w(owner admin editor viewer)} class="text-xs text-base-content/50">
              {role_description(role)}
            </li>
          </ul>

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
                  id={"member-role-#{member.id}"}
                  name={"role-#{member.id}"}
                  class="select select-bordered select-xs"
                  phx-change="set_member_role"
                  phx-value-user_id={member.id}
                >
                  <option
                    :for={role <- ~w(owner admin editor viewer)}
                    value={role}
                    selected={member.role == role}
                  >
                    {role_label(role)}
                  </option>
                </select>

                <button
                  type="button"
                  phx-click="toggle_member"
                  phx-value-user_id={member.id}
                  data-confirm={gettext("Remove %{user} from this workspace?", user: member.email)}
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

          <p class="text-xs text-base-content/60 mb-3">
            {gettext(
              "Give an existing account access to this workspace. People must already have a Dran account — there is no invitation email, access is granted as soon as you add them."
            )}
          </p>

          <%!-- Add by email (works for anyone, no need to search first) --%>
          <.form
            for={@invite_form}
            id="invite-member-form"
            phx-submit="invite_member"
            class="flex flex-wrap items-end gap-3 mb-4"
          >
            <div class="flex-1 min-w-56">
              <.input
                field={@invite_form[:email]}
                type="email"
                label={gettext("Email")}
                placeholder="ana@example.com"
              />
            </div>
            <div class="w-40">
              <.input
                field={@invite_form[:role]}
                type="select"
                label={gettext("Role")}
                options={role_options()}
              />
            </div>
            <button
              type="submit"
              class="btn btn-primary btn-sm mb-2 transition-colors active:scale-95"
              phx-disable-with={gettext("Adding…")}
            >
              <.icon name="hero-plus" class="size-4" />
              {gettext("Add")}
            </button>
          </.form>

          <%!-- The id keeps LiveView form recovery working (it is the field the
               form is about, and the one a crash would lose). --%>
          <form id="user-search-form" phx-change="search_users" class="relative">
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
        {key, Workspace.get_tuning(workspace, String.to_atom(key))}
      end)
      |> Map.update!("summary_language", &(&1 || "auto"))

    assign(socket, settings_form: to_form(values, as: :workspace))
  end

  defp assign_custom_type_form(socket) do
    assign(socket,
      custom_type_form: to_form(blank_custom_type_params(), as: :workspace),
      custom_type_error: nil
    )
  end

  # Values of the "add a custom page type" form. Kept as plain string-keyed
  # params so a rejected submit can be re-fed verbatim into `to_form/2`
  # (values survive the round-trip).
  defp blank_custom_type_params do
    Map.new(~w(slug label plural path icon color meta_fields), &{&1, ""})
  end

  # Same map, with one field replaced — used by the example/clear buttons.
  defp custom_type_form_params(socket, key, value) do
    case socket.assigns[:custom_type_form] do
      %{params: params} when is_map(params) ->
        params |> stringify_keys() |> Map.put(key, value)

      _ ->
        Map.put(blank_custom_type_params(), key, value)
    end
  end

  defp stringify_keys(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  # ── meta_fields: JSON editor parsing ──────────────────────────────────────
  #
  # The stored shape is the editor's internal array form: one array per field,
  # `[type, key, label]` (optionally with extra opts). Empty input means "no
  # custom fields" — not an error. Anything else that does not decode, or does
  # not describe a field, is reported with the reason instead of being silently
  # dropped (the old behaviour turned a typo into "no fields, saved fine").

  @meta_field_types ~w(text date props)

  defp parse_meta_fields(nil), do: {:ok, []}
  defp parse_meta_fields(""), do: {:ok, []}

  defp parse_meta_fields(raw) when is_binary(raw) do
    case String.trim(raw) do
      "" -> {:ok, []}
      trimmed -> decode_meta_fields(trimmed)
    end
  end

  defp parse_meta_fields(other) when is_list(other), do: {:ok, other}
  defp parse_meta_fields(_other), do: {:ok, []}

  defp decode_meta_fields(raw) do
    case Jason.decode(raw) do
      {:ok, list} when is_list(list) -> validate_meta_fields(list)
      {:ok, _other} -> {:error, gettext("Meta fields must be a JSON array of fields.")}
      {:error, %Jason.DecodeError{} = error} -> {:error, json_error_message(error)}
    end
  end

  defp validate_meta_fields(fields) do
    fields
    |> Enum.with_index(1)
    |> Enum.find_value(fn {field, index} -> meta_field_error(field, index) end)
    |> case do
      nil -> {:ok, fields}
      error -> {:error, error}
    end
  end

  defp meta_field_error(field, index) when is_list(field) do
    case field do
      # Two elements is enough to tell which piece is missing.
      [type, key | rest] ->
        label = List.first(rest)

        cond do
          type not in @meta_field_types ->
            gettext("Field %{index}: unknown type %{type}. Allowed types: %{allowed}.",
              index: index,
              type: inspect(type),
              allowed: Enum.join(@meta_field_types, ", ")
            )

          not (is_binary(key) and String.trim(key) != "") ->
            gettext("Field %{index}: the key must be a non-empty string.", index: index)

          not (is_binary(label) and String.trim(label) != "") ->
            gettext("Field %{index}: the label must be a non-empty string.", index: index)

          true ->
            nil
        end

      _ ->
        gettext(
          "Field %{index}: each field is a JSON array like [\"text\", \"cuisine\", \"Cuisine\"].",
          index: index
        )
    end
  end

  defp meta_field_error(_field, index) do
    gettext(
      "Field %{index}: each field is a JSON array like [\"text\", \"cuisine\", \"Cuisine\"].",
      index: index
    )
  end

  defp json_error_message(%Jason.DecodeError{} = error) do
    gettext("Invalid JSON: %{detail}", detail: Jason.DecodeError.message(error))
  end

  # Decoded view of what the editor currently holds, for the inline feedback
  # under the JSON box: `{:empty, []}`, `{:ok, fields}` or `{:error, message}`.
  defp meta_fields_feedback(nil), do: {:empty, []}
  defp meta_fields_feedback(""), do: {:empty, []}

  defp meta_fields_feedback(raw) when is_binary(raw) do
    case parse_meta_fields(raw) do
      {:ok, []} -> {:empty, []}
      {:ok, fields} -> {:ok, fields}
      {:error, message} -> {:error, message}
    end
  end

  defp meta_fields_feedback(_other), do: {:empty, []}

  # Ready-to-load templates. `key` is the DOM value, `json` goes straight into
  # the textarea so the shape is learned by example, not by documentation.
  defp meta_field_examples do
    [
      %{
        key: "text",
        label: gettext("Text field"),
        json: ~s([[\"text\", \"cuisine\", \"Cuisine\"]])
      },
      %{
        key: "date_url",
        label: gettext("Date + URL"),
        json:
          ~s([[\"date\", \"published_at\", \"Published at\"], [\"text\", \"source_url\", \"Source URL\"]])
      },
      %{
        key: "props",
        label: gettext("Custom properties"),
        json: ~s([[\"props\", \"props\", \"Custom properties\"]])
      }
    ]
  end

  # Live preview of the type being defined, computed from the form values.
  # `slug`/`path` stay nil when blank so callers can show their own default.
  defp custom_type_preview(params) when is_map(params) do
    params = stringify_keys(params)
    label = blank_to_nil(params["label"]) || gettext("New type")
    plural = blank_to_nil(params["plural"]) || label <> "s"

    %{
      label: label,
      plural: plural,
      slug: blank_to_nil(params["slug"]),
      path: blank_to_nil(params["path"]),
      icon: preview_icon(params["icon"]),
      color: preview_color(params["color"])
    }
  end

  defp custom_type_preview(_), do: custom_type_preview(%{})

  # Mirrors `Dran.Workspace.normalize_icon/1` so the preview shows the icon
  # that will actually be stored (the `hero-` prefix is added automatically).
  defp preview_icon(nil), do: "hero-document-text"

  defp preview_icon(value) when is_binary(value) do
    case String.trim(value) do
      "" -> "hero-document-text"
      "hero-" <> _ = icon -> icon
      other -> "hero-" <> other
    end
  end

  defp preview_icon(_), do: "hero-document-text"

  defp preview_color(nil), do: "#94A3B8"
  defp preview_color(""), do: "#94A3B8"
  defp preview_color(value) when is_binary(value), do: String.trim(value)
  defp preview_color(_), do: "#94A3B8"

  # One-line description of a parsed meta field for the editor chips.
  defp meta_field_chip([type, key | _rest]), do: "#{type} · #{key}"
  defp meta_field_chip(other), do: inspect(other)

  defp custom_type_message(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> Map.get(:workspace_page_types, [])
    |> List.first()
    |> case do
      nil -> gettext("Could not save the page type")
      message -> message
    end
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
    |> Map.update("summary_language", "auto", &blank_to_auto/1)
  end

  # Blank/missing language resets to "auto" (follows each page's language).
  defp blank_to_auto(""), do: "auto"
  defp blank_to_auto(value), do: value

  # Rebuilds the full enabled_features map with real booleans. Unchecked
  # checkboxes are absent from the params, so every feature is set explicitly.
  defp features_attrs(params) do
    raw = Map.get(params, "enabled_features", %{})

    Map.new(@features, fn feature ->
      {feature, Map.get(raw, feature) == "true"}
    end)
  end

  # Los toggles de compartición viven en el sub-map `workspace` (como el
  # resto de campos del workspace). Un checkbox sin marcar no llega: solo el
  # hidden input envía "false", así que ausente = false.
  defp share_attr(params, key) do
    ws_params = Map.get(params, "workspace", %{})
    Map.get(ws_params, key) == "true"
  end

  # Blank form values become nil so callers can fall back to a default.
  # Trims first: a field holding only spaces is blank, not a value.
  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  # Select options for the summary language pin. "Auto" keeps the model
  # matching each page/transcript's own language (the historical default).
  defp summary_language_options do
    [
      {gettext("Auto (matches each page's language)"), "auto"},
      {gettext("Spanish"), "es"},
      {gettext("English"), "en"}
    ]
  end

  # Effective types come from the workspace (4 built-in ∪ custom); labels,
  # icons, colours and paths all resolve through `Dran.Workspace.page_type_ui/2`
  # in the template, so a custom type shows its declared values.
  defp effective_page_types(workspace), do: Dran.Knowledge.effective_page_types(workspace)

  defp feature_label("clusters"), do: gettext("Clusters")
  defp feature_label("graph"), do: gettext("Graph")
  defp feature_label("journey"), do: gettext("Journey")
  defp feature_label("collections"), do: gettext("Collections")
  defp feature_label("activity"), do: gettext("Activity")
  defp feature_label("search"), do: gettext("Search")
  defp feature_label("reports"), do: gettext("Reports")
  defp feature_label(other), do: other

  # What the user loses by turning the feature off — the caption next to each
  # toggle. Written as "what it gives you", because that is the decision the
  # toggle asks for.
  defp feature_description("search"),
    do: gettext("Full-text and semantic search across this workspace's pages.")

  defp feature_description("graph"),
    do: gettext("The relationship map of this workspace's pages.")

  defp feature_description("journey"),
    do: gettext("Timeline of how this workspace's knowledge grew over time.")

  defp feature_description("collections"),
    do: gettext("Curated and smart page lists that update as the workspace changes.")

  defp feature_description("clusters"),
    do: gettext("Related pages grouped into themes by the nightly job.")

  defp feature_description("reports"),
    do: gettext("Generated reports written from this workspace's content.")

  defp feature_description("activity"),
    do: gettext("Log of the recent changes to this workspace's pages.")

  defp feature_description(_other), do: ""

  defp group_label("Knowledge base"), do: gettext("Knowledge base")
  defp group_label("Insights"), do: gettext("Insights")
  defp group_label(other), do: other

  # Role labels come from gettext instead of `String.capitalize/1`: the raw
  # role slugs ("owner", "viewer") are stored values, not user-facing text.
  defp role_label("owner"), do: gettext("Owner")
  defp role_label("admin"), do: gettext("Admin")
  defp role_label("editor"), do: gettext("Editor")
  defp role_label("viewer"), do: gettext("Viewer")
  defp role_label(other), do: other

  # Options for the invite form. "owner" is deliberately absent: the workspace
  # already has an owner (whoever created it), and handing out ownership is a
  # deliberate two-step decision from the member list — not a dropdown default.
  defp role_options do
    Enum.map(~w(admin editor viewer), &{role_label(&1), &1})
  end

  # One line per role, rendered as a legend above the member list: picking a
  # role is a permission decision and the options are otherwise just words.
  defp role_description("owner"),
    do: gettext("Owner: settings, members and content.")

  defp role_description("admin"),
    do: gettext("Admin: settings and members, plus content.")

  defp role_description("editor"),
    do: gettext("Editor: create and edit pages, no access to settings.")

  defp role_description("viewer"),
    do: gettext("Viewer: read pages only.")

  defp role_description(_other), do: ""
end
