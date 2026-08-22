defmodule DranWeb.SettingsLive do
  @moduledoc """
  Settings page for the logged-in user's PERSONAL API keys.

  After the F3 /admin split, each user manages only their own context-scoped
  API keys here. Instance-level configuration (users, workspaces, models,
  system info, jobs) lives in the owner-only `/admin/*` LiveViews. The old
  `attach_hook(:require_admin)` whitelist was removed (corrección #8): it
  silently dropped `regenerate_api_key` and `delete_api_key` for non-owners,
  so a regular user could not manage their own keys. Now every api_key event
  is allowed for any logged-in session — ownership is enforced per-key by
  `owned_api_key/2`, never by the admin flag.
  """

  use DranWeb, :live_view

  import DranWeb.Admin

  alias DranWeb.Plugs.Auth

  # Workspaces the user may attach to a NEW api key: those where they are a
  # member. Instance owners may use any workspace.
  defp api_key_workspaces(nil), do: []

  defp api_key_workspaces(%{is_owner: true}) do
    Dran.Knowledge.list_workspaces()
  end

  defp api_key_workspaces(user) do
    Dran.Accounts.list_user_workspaces(user)
  end

  @impl true
  def mount(params, session, socket) do
    {socket, _context} = Auth.assign_to_socket(socket, session)

    user = session_user(session)

    socket =
      socket
      |> assign(
        active_nav: "settings",
        page_title: gettext("Settings"),
        workspace_slug: nil,
        current_user_struct: user
      )
      |> assign(
        api_keys: Dran.Accounts.list_api_keys(user),
        api_key_workspaces: api_key_workspaces(user),
        new_api_key_form: to_form(%{}, as: :api_key),
        revealed_api_key: nil,
        show_api_key_modal: false,
        profile_form: to_form(Dran.Accounts.User.profile_changeset(user, %{}), as: :profile),
        password_form:
          to_form(Dran.Accounts.User.update_password_changeset(user, %{}), as: :password),
        google_linked: Dran.Accounts.google_linked?(user)
      )

    {:ok, apply_tab(socket, socket.assigns.live_action, params)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, apply_tab(socket, socket.assigns.live_action, %{})}
  end

  defp apply_tab(socket, :account, _params) do
    socket
    |> assign(active_tab: :account, page_title: gettext("Account"))
  end

  defp apply_tab(socket, :api_keys, _params) do
    socket
    |> assign(active_tab: :api_keys, page_title: gettext("API Keys"))
  end

  defp apply_tab(socket, _action, _params) do
    socket
    |> assign(active_tab: :api_keys, page_title: gettext("API Keys"))
  end

  # Resolves the %User{} (or nil) behind the LiveView session. The session
  # stores the email; `nil` falls back to the no-user case (empty key lists).
  defp session_user(session) do
    case Auth.from_session(session) do
      %{current_user: email} when is_binary(email) ->
        Dran.Accounts.get_user_by_email(email)

      _ ->
        nil
    end
  end

  @impl true
  def handle_event("open_api_key_modal", _params, socket) do
    {:noreply, assign(socket, show_api_key_modal: true)}
  end

  @impl true
  def handle_event("close_api_key_modal", _params, socket) do
    {:noreply, assign(socket, show_api_key_modal: false)}
  end

  @impl true
  def handle_event("create_api_key", %{"api_key" => params}, socket) do
    name = Map.get(params, "name", "") |> String.trim()

    # The modal submits one checkbox per workspace (`api_key[workspaces][id]`)
    # plus a level select (`api_key[level][id]` = read|write). Unticked
    # workspaces are absent from the params entirely.
    levels = Map.get(params, "level", %{})

    workspace_ids =
      params
      |> Map.get("workspaces", %{})
      |> Enum.reject(fn {_wid, ticked} -> ticked in [nil, "", "off", "false"] end)
      |> Enum.map(fn {wid, _ticked} ->
        level = if levels[wid] == "write", do: "write", else: "read"
        {wid, level}
      end)

    user = socket.assigns[:current_user_struct] || session_user_via_assigns(socket)

    attrs = %{
      name: name,
      workspace_ids: workspace_ids,
      created_by_user_id: user && user.id
    }

    case Dran.Accounts.create_api_key(attrs) do
      {:ok, key} ->
        socket =
          socket
          |> assign(
            api_keys: Dran.Accounts.list_api_keys(user),
            new_api_key_form: to_form(%{}, as: :api_key),
            revealed_api_key: %{id: key.id, token: key.token},
            show_api_key_modal: false
          )
          |> put_flash(:info, gettext("API key created — copy it now, it won't be shown again"))

        {:noreply, socket}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(new_api_key_form: to_form(changeset, as: :api_key))
         |> put_flash(:error, gettext("Could not create the API key"))}

      {:error, :workspace_not_allowed} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("You can only grant access to your own workspaces"))}
    end
  end

  @impl true
  def handle_event("dismiss_revealed_key", _params, socket) do
    {:noreply, assign(socket, revealed_api_key: nil)}
  end

  @impl true
  def handle_event("revoke_api_key", %{"id" => id}, socket) do
    with {:ok, key} <- owned_api_key(id, socket),
         {:ok, _} <- Dran.Accounts.revoke_api_key(key) do
      {:noreply,
       socket
       |> assign(api_keys: current_api_keys(socket))
       |> put_flash(:info, gettext("API key revoked"))}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("No autorizado."))}
    end
  end

  @impl true
  def handle_event("restore_api_key", %{"id" => id}, socket) do
    with {:ok, key} <- owned_api_key(id, socket),
         {:ok, _} <- Dran.Accounts.restore_api_key(key) do
      {:noreply,
       socket
       |> assign(api_keys: current_api_keys(socket))
       |> put_flash(:info, gettext("API key restored"))}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("No autorizado."))}
    end
  end

  @impl true
  def handle_event("regenerate_api_key", %{"id" => id}, socket) do
    with {:ok, key} <- owned_api_key(id, socket),
         {:ok, key} <- Dran.Accounts.regenerate_api_key(key) do
      {:noreply,
       socket
       |> assign(
         api_keys: current_api_keys(socket),
         revealed_api_key: %{id: key.id, token: key.token}
       )
       |> put_flash(:info, gettext("API key regenerated — copy the new token now"))}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("No autorizado."))}
    end
  end

  @impl true
  def handle_event("delete_api_key", %{"id" => id}, socket) do
    with {:ok, key} <- owned_api_key(id, socket),
         {:ok, _} <- Dran.Accounts.delete_api_key(key) do
      {:noreply,
       socket
       |> assign(api_keys: current_api_keys(socket))
       |> put_flash(:info, gettext("API key deleted"))}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("No autorizado."))}
    end
  end

  @impl true
  def handle_event("copy_api_key_prefix", %{"id" => id}, socket) do
    key = Dran.Repo.get!(Dran.Accounts.ApiKey, id)
    {:noreply, push_event(socket, "copy_to_clipboard", %{text: key.token_prefix})}
  end

  # ── Account tab ──

  @impl true
  def handle_event("save_profile", %{"profile" => profile_params}, socket) do
    case Dran.Accounts.update_profile(socket.assigns.current_user_struct, profile_params) do
      {:ok, updated_user} ->
        socket =
          socket
          |> put_flash(:info, gettext("Profile updated"))
          |> assign(
            current_user_struct: updated_user,
            profile_form:
              to_form(Dran.Accounts.User.profile_changeset(updated_user, %{}), as: :profile)
          )

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, profile_form: to_form(changeset, as: :profile))}
    end
  end

  @impl true
  def handle_event("save_password", %{"password" => password_params}, socket) do
    case Dran.Accounts.update_password(socket.assigns.current_user_struct, password_params) do
      {:ok, _updated_user} ->
        socket =
          socket
          |> put_flash(:info, gettext("Password changed"))
          |> assign(
            password_form:
              to_form(
                Dran.Accounts.User.update_password_changeset(
                  socket.assigns.current_user_struct,
                  %{}
                ),
                as: :password
              )
          )

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, password_form: to_form(changeset, as: :password))}
    end
  end

  @impl true
  def handle_event("unlink_google", _params, socket) do
    case Dran.Accounts.unlink_google(socket.assigns.current_user_struct) do
      {:ok, updated_user} ->
        socket =
          socket
          |> put_flash(:info, gettext("Google account unlinked"))
          |> assign(current_user_struct: updated_user, google_linked: false)

        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Could not unlink Google account"))}
    end
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
          <div class="flex items-center gap-1 border-b border-base-300">
            <.tab_link active={@active_tab == :account} to={~p"/settings/account"}>
              {gettext("Account")}
            </.tab_link>
            <.tab_link active={@active_tab == :api_keys} to={~p"/settings/api_keys"}>
              {gettext("API Keys")}
            </.tab_link>
          </div>

          <%= if @active_tab == :account do %>
            <div class="space-y-6">
              <.section
                title={gettext("Profile")}
                caption={gettext("Change your display name.")}
                icon="hero-user"
              >
                <.form
                  for={@profile_form}
                  id="profile-form"
                  phx-submit="save_profile"
                  class="space-y-4"
                >
                  <.input
                    field={@profile_form[:name]}
                    label={gettext("Name")}
                    placeholder={gettext("Your name")}
                  />
                  <button
                    type="submit"
                    class="btn btn-primary btn-sm"
                    phx-disable-with={gettext("Saving…")}
                  >
                    {gettext("Save")}
                  </button>
                </.form>
              </.section>

              <.section
                title={gettext("Password")}
                caption={gettext("Change your password.")}
                icon="hero-lock-closed"
              >
                <.form
                  for={@password_form}
                  id="password-form"
                  phx-submit="save_password"
                  class="space-y-4"
                >
                  <.input
                    :if={@current_user_struct.password_hash}
                    field={@password_form[:current_password]}
                    type="password"
                    label={gettext("Current password")}
                    placeholder="••••••••"
                  />
                  <.input
                    field={@password_form[:password]}
                    type="password"
                    label={gettext("New password")}
                    placeholder="••••••••"
                  />
                  <button
                    type="submit"
                    class="btn btn-primary btn-sm"
                    phx-disable-with={gettext("Saving…")}
                  >
                    {gettext("Change password")}
                  </button>
                </.form>
              </.section>

              <.section
                title={gettext("Google Account")}
                caption={gettext("Link or unlink your Google account.")}
                icon="hero-globe-alt"
              >
                <div class="flex items-center gap-3">
                  <.icon
                    name={if @google_linked, do: "hero-check-badge", else: "hero-link-slash"}
                    class="size-5"
                  />
                  <span class="text-sm text-base-content/70">
                    {if @google_linked,
                      do: gettext("Google account linked"),
                      else: gettext("No Google account linked")}
                  </span>
                </div>

                <div class="mt-4">
                  <%= if @google_linked do %>
                    <button
                      type="button"
                      phx-click="unlink_google"
                      data-confirm={gettext("Are you sure you want to unlink your Google account?")}
                      class="btn btn-ghost btn-sm gap-1.5 text-error"
                      phx-disable-with={gettext("Unlinking…")}
                    >
                      <.icon name="hero-link-slash" class="size-4" />
                      {gettext("Unlink")}
                    </button>
                  <% else %>
                    <a href={~p"/auth/google"} class="btn btn-outline btn-sm gap-1.5">
                      <.icon name="hero-globe-alt" class="size-4" />
                      {gettext("Link Google account")}
                    </a>
                  <% end %>
                </div>
              </.section>
            </div>
          <% else %>
            <div id="api-keys-tab" phx-hook=".CopyUserToken">
              <.api_keys_section
                api_keys={@api_keys}
                all_workspaces={@api_key_workspaces}
                api_key_workspaces={@api_key_workspaces}
                form={@new_api_key_form}
                revealed_api_key={@revealed_api_key}
                show_api_key_modal={@show_api_key_modal}
              />
            </div>
          <% end %>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # ── Tabs ──

  attr :active, :boolean, default: false
  attr :to, :any, required: true
  slot :inner_block, required: true

  defp tab_link(assigns) do
    ~H"""
    <.link
      patch={@to}
      class={[
        "px-4 py-2 text-sm font-medium border-b-2 -mb-px transition-colors duration-150",
        @active && "border-primary text-primary",
        !@active && "border-transparent text-base-content/60 hover:text-base-content"
      ]}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  # ── API Keys section ──────────────────────────────────────────────────────

  attr :api_keys, :list, required: true
  attr :all_workspaces, :list, required: true
  attr :api_key_workspaces, :list, default: []
  attr :form, :map, required: true
  attr :revealed_api_key, :map, default: nil
  attr :show_api_key_modal, :boolean, default: false

  def api_keys_section(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-title">{gettext("API Keys")}</h1>
          <p class="text-caption mt-1">
            {gettext(
              "Context-scoped keys for integrations and MCP clients. A key grants access to one context only — no user account needed."
            )}
          </p>
        </div>
        <button
          phx-click="open_api_key_modal"
          class="btn btn-primary btn-sm gap-1.5"
        >
          <.icon name="hero-plus" class="size-4" />
          {gettext("Add Key")}
        </button>
      </div>

      <%!-- Newly created / regenerated token — shown ONCE --%>
      <div
        :if={@revealed_api_key}
        class="card bg-success/10 border border-success/40"
        id="revealed-api-key-card"
      >
        <div class="card-body py-4 space-y-3">
          <div class="flex items-center justify-between">
            <h3 class="font-semibold text-success flex items-center gap-2">
              <.icon name="hero-key" class="size-5" />
              {gettext("Copy your new API key now — it won't be shown again")}
            </h3>
            <button
              type="button"
              phx-click="dismiss_revealed_key"
              class="btn btn-ghost btn-xs p-1"
              title={gettext("Dismiss")}
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </div>
          <div class="flex items-center gap-2">
            <code
              id="revealed-api-key-token"
              data-token={@revealed_api_key.token}
              class="flex-1 text-sm font-mono bg-base-100 rounded-md px-3 py-2 border border-success/40 select-all break-all"
            >
              {@revealed_api_key.token}
            </code>
            <button
              type="button"
              id="copy-revealed-key-btn"
              phx-hook=".CopyApiToken"
              class="btn btn-success btn-sm gap-1 transition-all active:scale-95"
            >
              <span data-copy-icon class="flex items-center gap-1">
                <.icon name="hero-clipboard-document" class="size-4" />
                {gettext("Copy")}
              </span>
              <span data-check-icon class="hidden items-center gap-1">
                <.icon name="hero-clipboard-document-check" class="size-4" />
                {gettext("Copied!")}
              </span>
            </button>
          </div>
        </div>
      </div>

      <%!-- Keys list --%>
      <.section
        :if={@api_keys != []}
        title={gettext("Existing Keys")}
        icon="hero-key"
      >
        <div class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>{gettext("Name")}</th>
                <th>{gettext("Context")}</th>
                <th>{gettext("Token")}</th>
                <th>{gettext("Status")}</th>
                <th>{gettext("Write")}</th>
                <th>{gettext("Created")}</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={key <- @api_keys} id={"api-key-#{key.id}"}>
                <td class="font-medium">{key.name}</td>
                <td>
                  <span class="badge badge-ghost badge-sm">
                    {if Enum.any?(key.api_key_workspaces),
                      do: hd(key.api_key_workspaces).workspace.name,
                      else: "—"}
                  </span>
                </td>
                <td>
                  <div class="flex items-center gap-1">
                    <code class="text-xs">{key.token_prefix}••••••••••••</code>
                    <button
                      type="button"
                      phx-click="copy_api_key_prefix"
                      phx-value-id={key.id}
                      class="btn btn-ghost btn-xs p-1"
                      title={gettext("Copy prefix")}
                    >
                      <.icon name="hero-clipboard-document" class="size-3.5" />
                    </button>
                  </div>
                </td>
                <td>
                  <span :if={key.revoked_at} class="badge badge-error badge-sm">
                    {gettext("Revoked")}
                  </span>
                  <span :if={!key.revoked_at} class="badge badge-success badge-sm">
                    {gettext("Active")}
                  </span>
                </td>
                <td>
                  <button
                    type="button"
                    phx-click="toggle_write_access"
                    phx-value-id={key.id}
                    class="btn btn-ghost btn-xs p-1"
                    title={
                      if Dran.Accounts.ApiKey.write_access?(key),
                        do: gettext("Click to make read-only"),
                        else: gettext("Click to enable write access")
                    }
                  >
                    <span
                      :if={Dran.Accounts.ApiKey.write_access?(key)}
                      class="badge badge-primary badge-sm"
                    >
                      {gettext("R/W")}
                    </span>
                    <span
                      :if={!Dran.Accounts.ApiKey.write_access?(key)}
                      class="badge badge-ghost badge-sm"
                    >
                      {gettext("R/O")}
                    </span>
                  </button>
                </td>
                <td class="text-xs text-base-content/60">
                  {Calendar.strftime(key.inserted_at, "%Y-%m-%d")}
                </td>
                <td>
                  <div class="flex items-center gap-1 justify-end">
                    <button
                      :if={!key.revoked_at}
                      type="button"
                      phx-click="revoke_api_key"
                      phx-value-id={key.id}
                      data-confirm={gettext("Revoke this key? It will stop working immediately.")}
                      class="btn btn-ghost btn-xs p-1 text-warning"
                      title={gettext("Revoke")}
                    >
                      <.icon name="hero-no-symbol" class="size-4" />
                    </button>
                    <button
                      :if={key.revoked_at}
                      type="button"
                      phx-click="restore_api_key"
                      phx-value-id={key.id}
                      class="btn btn-ghost btn-xs p-1 text-success"
                      title={gettext("Restore")}
                    >
                      <.icon name="hero-arrow-uturn-left" class="size-4" />
                    </button>
                    <button
                      type="button"
                      phx-click="regenerate_api_key"
                      phx-value-id={key.id}
                      data-confirm={
                        gettext(
                          "Regenerate this key? The current token stops working immediately and you'll get a new one."
                        )
                      }
                      class="btn btn-ghost btn-xs p-1"
                      title={gettext("Regenerate")}
                    >
                      <.icon name="hero-arrow-path" class="size-4" />
                    </button>
                    <button
                      type="button"
                      phx-click="delete_api_key"
                      phx-value-id={key.id}
                      data-confirm={gettext("Delete this key permanently?")}
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

      <div :if={@api_keys == []} class="text-center text-base-content/50 py-6">
        {gettext("No API keys yet — create one with the button above.")}
      </div>

      <%!-- Create API key modal --%>
      <.modal
        id="api-key-modal"
        show={@show_api_key_modal}
        title={gettext("Create API Key")}
        on_close="close_api_key_modal"
      >
        <.form for={@form} phx-submit="create_api_key" class="space-y-4" id="create-api-key-form">
          <.input
            field={@form[:name]}
            label={gettext("Name")}
            type="text"
            placeholder={gettext("e.g. Hermes agent, backup script")}
            required
          />

          <div>
            <p class="text-sm font-medium mb-2">
              {gettext("Workspaces")} — {gettext("tick the ones this key may access")}
            </p>
            <div class="space-y-2 max-h-60 overflow-y-auto">
              <div :for={ws <- @api_key_workspaces} class="flex items-center gap-3">
                <label class="flex items-center gap-2 cursor-pointer">
                  <input
                    type="checkbox"
                    name={"api_key[workspaces][#{ws.id}]"}
                    value="read"
                    class="checkbox checkbox-sm"
                  />
                  <span class="text-sm">{ws.name}</span>
                </label>
                <select
                  name={"api_key[level][#{ws.id}]"}
                  class="select select-bordered select-xs ml-auto"
                >
                  <option value="read">{gettext("Read only")}</option>
                  <option value="write">{gettext("Read + write")}</option>
                </select>
              </div>
            </div>
            <p :if={@api_key_workspaces == []} class="text-sm text-base-content/60">
              {gettext("You are not a member of any workspace yet.")}
            </p>
          </div>

          <div class="flex justify-end gap-2 pt-2">
            <button
              type="button"
              phx-click="close_api_key_modal"
              class="btn btn-ghost btn-sm"
            >
              {gettext("Cancel")}
            </button>
            <button
              type="submit"
              class="btn btn-primary btn-sm"
              phx-disable-with={gettext("Guardando…")}
            >
              {gettext("Create Key")}
            </button>
          </div>
        </.form>
      </.modal>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyApiToken">
        export default {
          mounted() {
            this.el.addEventListener("click", () => {
              const target = document.getElementById("revealed-api-key-token");
              if (!target) return;
              const text = target.dataset.token;
              if (!text) return;
              const copied = () => {
                const icon = this.el.querySelector("[data-copy-icon]");
                const check = this.el.querySelector("[data-check-icon]");
                if (icon && check) {
                  icon.classList.add("hidden");
                  check.classList.remove("hidden");
                  check.classList.add("flex");
                  setTimeout(() => {
                    icon.classList.remove("hidden");
                    check.classList.add("hidden");
                    check.classList.remove("flex");
                  }, 1500);
                }
              };
              if (navigator.clipboard && navigator.clipboard.writeText) {
                navigator.clipboard.writeText(text).then(copied);
              } else {
                const ta = document.createElement("textarea");
                ta.value = text;
                ta.setAttribute("readonly", "");
                ta.style.position = "absolute";
                ta.style.left = "-9999px";
                document.body.appendChild(ta);
                ta.select();
                try { document.execCommand("copy"); } catch (_e) { /* noop */ }
                document.body.removeChild(ta);
                copied();
              }
            });
          }
        }
      </script>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyUserToken">
        export default {
          mounted() {
            this.handleEvent("copy_to_clipboard", ({ text }) => {
              const fallback = () => {
                const ta = document.createElement("textarea");
                ta.value = text;
                ta.setAttribute("readonly", "");
                ta.style.position = "absolute";
                ta.style.left = "-9999px";
                document.body.appendChild(ta);
                ta.select();
                try { document.execCommand("copy"); } catch (_e) { /* noop */ }
                document.body.removeChild(ta);
              };
              if (navigator.clipboard && navigator.clipboard.writeText) {
                navigator.clipboard.writeText(text).catch(fallback);
              } else {
                fallback();
              }
            });
          }
        }
      </script>
    </div>
    """
  end

  # The %User{} struct is not stored in assigns by default (only the email);
  # resolve it lazily from the assign on the event paths that need the struct.
  defp session_user_via_assigns(socket) do
    with email when is_binary(email) <- socket.assigns[:current_user],
         %{} = user <- Dran.Accounts.get_user_by_email(email) do
      user
    else
      _ -> nil
    end
  end

  # A key may only be managed by its creator or an instance owner.
  defp owned_api_key(id, socket) do
    user = session_user_via_assigns(socket)

    cond do
      socket.assigns[:is_owner] ->
        {:ok, Dran.Repo.get!(Dran.Accounts.ApiKey, id)}

      is_map(user) ->
        key = Dran.Repo.get!(Dran.Accounts.ApiKey, id)

        if key.created_by_user_id == user.id,
          do: {:ok, key},
          else: {:error, :not_owner}

      true ->
        {:error, :not_owner}
    end
  end

  defp current_api_keys(socket) do
    Dran.Accounts.list_api_keys(session_user_via_assigns(socket))
  end
end
