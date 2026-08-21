defmodule DranWeb.WorkspaceSettingsLive do
  @moduledoc """
  Workspace configuration page: page types, enabled features, and brain
  tuning for a single workspace.

  Access is enforced by the `:workspace_admin` router pipeline (owner/admin of
  the workspace ∪ instance owner) plus an `attach_hook` defense-in-depth that
  halts every event for non-owners/admins.

  The workspace is resolved from the URL slug (`params["workspace_slug"]`),
  NOT from the session — a user in session workspace "personal" navigating to
  `/work/settings` edits "work" (corrección #10). The role guard also computes
  the role from the URL slug's workspace (corrección #11).
  """

  use DranWeb, :live_view

  alias Dran.Accounts
  alias Dran.Knowledge
  alias Dran.Repo
  alias Dran.Workspace
  alias DranWeb.Plugs.Auth

  # Ordered feature keys shown in the Features card. All are stored in the
  # `enabled_features` map; an empty map means "all on" (see
  # `Workspace.feature_enabled?/2`).
  @features ~w(goals collections communities kanban graph journey activity search reports chat agents)

  # Brain tuning keys: agent limits + advanced semantic thresholds.
  @brain_keys ~w(agent_max_pages entity_linker_enabled)
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
        active_nav: "settings",
        page_title: gettext("Workspace settings"),
        current_user_struct: user,
        workspace: workspace,
        workspace_slug: slug,
        workspace_role: role
      )
      |> assign_settings_form()
      # Corrección #11: defense-in-depth — halt every event for users who are
      # not owner/admin of the URL workspace (same pattern as the old
      # SettingsLive `attach_hook(:require_admin, :handle_event, ...)`).
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
      active_nav="settings"
    >
      <div class="flex-1 overflow-y-auto">
        <div class="w-full p-6 space-y-8">
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

          <div :if={@workspace} class="space-y-8">
            <.page_types_section workspace={@workspace} />
            <.features_section workspace={@workspace} form={@settings_form} />
            <.brain_tuning_section workspace={@workspace} form={@settings_form} />
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # -- Event handlers ---------------------------------------------------------

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

  # -- View components --------------------------------------------------------

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
          <p class="text-caption mt-0.5">
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

  defp features_section(assigns) do
    ~H"""
    <section class="surface-2 rounded-2xl overflow-hidden">
      <header class="flex items-start gap-3 px-5 py-4 border-b border-base-content/10">
        <div class="shrink-0 size-8 rounded-lg flex items-center justify-center bg-accent/10">
          <.icon name="hero-puzzle-piece" class="size-4 text-accent" />
        </div>
        <div class="min-w-0">
          <h2 class="text-heading">{gettext("Features")}</h2>
          <p class="text-caption mt-0.5">
            {gettext(
              "Enable or disable workspace features. Disabled features hide their entry points."
            )}
          </p>
        </div>
      </header>

      <div class="px-5 py-5">
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
          <p class="text-caption mt-0.5">
            {gettext("Semantic thresholds and agent limits for this workspace.")}
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
          <%!-- Agent limits --%>
          <div class="space-y-2">
            <h3 class="text-caption font-semibold text-base-content/60 uppercase tracking-wider">
              {gettext("Agent limits")}
            </h3>
            <div class="space-y-4">
              <div>
                <.input
                  field={@form[:agent_max_pages]}
                  type="number"
                  label={gettext("Max pages per run")}
                />
                <p class="text-xs text-base-content/60 mt-1.5">
                  {gettext(
                    "Maximum number of pages the autonomous agents will create in a single run. Blank uses the global default."
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

  # Normalizes the brain tuning params: blank number inputs become nil (so the
  # global default applies) and the entity linker checkbox becomes a real
  # boolean.
  defp brain_attrs(params) do
    ws_params = Map.get(params, "workspace", %{})

    ws_params
    |> Map.update("semantic_threshold_short", nil, &blank_to_nil/1)
    |> Map.update("semantic_threshold_mid", nil, &blank_to_nil/1)
    |> Map.update("semantic_threshold_long", nil, &blank_to_nil/1)
    |> Map.update("agent_max_pages", nil, &blank_to_nil/1)
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
  defp feature_label("communities"), do: gettext("Communities")
  defp feature_label("kanban"), do: gettext("Kanban")
  defp feature_label("graph"), do: gettext("Graph")
  defp feature_label("journey"), do: gettext("Journey")
  defp feature_label("activity"), do: gettext("Activity")
  defp feature_label("search"), do: gettext("Search")
  defp feature_label("reports"), do: gettext("Reports")
  defp feature_label("chat"), do: gettext("Chat")
  defp feature_label("agents"), do: gettext("Agents")
  defp feature_label(other), do: other
end
