defmodule DranWeb.SettingsLive do
  @moduledoc """
  Settings page for the logged-in user's PERSONAL API keys.

  After the F3 /admin split, each user manages only their own context-scoped
  API keys here. Instance-level configuration (users, workspaces, models,
  system info, jobs) lives in the owner-only `/admin/*` LiveViews.

  ## W3 (M5) — `/settings/api-keys`, sin CRUD de actores

  The tab is `/settings/api-keys` and shows ONLY API key management: the key
  **name** is the agent identity and the key's workspace×level matrix
  (`api_key_workspaces`) is edited inline. The actor CRUD was removed together
  with its LiveView events (`create_actor`/`edit_actor`/`update_actor`/
  `delete_actor`/`confirm_delete_actor`/`cancel_edit_actor`) — actors are no
  longer part of the key lifecycle (`Dran.Actors` keeps its `kind: user` /
  `kind: system` responsibilities and its CRUD functions; `list_managed_actors/0`
  is intentionally left in the module even though this UI was its only caller,
  per the W3 decision not to delete the module while ?03 is open).

  Events are allowed for any logged-in session — ownership is enforced per-key
  by `owned_api_key/2`, never by the admin flag.
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
        revealed_api_key: nil,
        show_create_key_modal: false,
        create_key_form: nil,
        editing_key_id: nil,
        edit_key_form: nil,
        profile_form: to_form(Dran.Accounts.User.profile_changeset(user, %{}), as: :profile),
        password_form:
          to_form(Dran.Accounts.User.update_password_changeset(user, %{}), as: :password),
        locale_form: locale_form(socket.assigns.locale),
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
    |> assign(active_tab: :api_keys, page_title: gettext("API keys"))
    |> assign(
      api_keys: current_api_keys(socket),
      show_create_key_modal: false,
      create_key_form: nil,
      editing_key_id: nil,
      edit_key_form: nil
    )
  end

  defp apply_tab(socket, _action, _params) do
    socket
    |> assign(active_tab: :api_keys, page_title: gettext("API keys"))
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
  def handle_event("dismiss_revealed_key", _params, socket) do
    {:noreply, assign(socket, revealed_api_key: nil)}
  end

  # ── Create key: key name + workspace×level matrix ─────────────────────────

  @impl true
  def handle_event("open_create_key_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(show_create_key_modal: true)
     |> assign(create_key_form: key_form(socket.assigns.api_key_workspaces))}
  end

  @impl true
  def handle_event("close_create_key_modal", _params, socket) do
    {:noreply, assign(socket, show_create_key_modal: false, create_key_form: nil)}
  end

  @impl true
  def handle_event("create_api_key", %{"key" => key_params}, socket) do
    user = socket.assigns[:current_user_struct] || session_user_via_assigns(socket)

    name = key_params |> Map.get("name", "") |> to_string() |> String.trim()

    if name == "" do
      {:noreply, put_flash(socket, :error, gettext("The key name is required"))}
    else
      with {:ok, workspace_ids} <- parse_key_workspaces(key_params),
           {:ok, key} <-
             Dran.Accounts.create_api_key(%{
               name: name,
               workspace_ids: workspace_ids,
               created_by_user_id: user && user.id
             }) do
        {:noreply,
         socket
         |> assign(
           api_keys: current_api_keys(socket),
           revealed_api_key: %{id: key.id, token: key.token},
           show_create_key_modal: false,
           create_key_form: nil
         )
         |> put_flash(
           :info,
           gettext("API key created — copy it now, it won't be shown again")
         )}
      else
        {:error, :workspace_not_allowed} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("You can only grant access to your own workspaces")
           )}

        _ ->
          {:noreply, put_flash(socket, :error, gettext("Could not create the API key"))}
      end
    end
  end

  # ── Key access matrix (post-creation editing) ─────────────────────────────

  @impl true
  def handle_event("edit_api_key", %{"id" => key_id}, socket) do
    with {:ok, key} <- owned_api_key(key_id, socket) do
      key = Dran.Repo.preload(key, :api_key_workspaces)

      socket =
        socket
        |> assign(editing_key_id: key.id)
        |> assign(edit_key_form: key_form(socket.assigns.api_key_workspaces, key))

      {:noreply, socket}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Not authorized."))}
    end
  end

  @impl true
  def handle_event("close_edit_key_modal", _params, socket) do
    {:noreply, assign(socket, editing_key_id: nil, edit_key_form: nil)}
  end

  @impl true
  def handle_event("update_api_key_access", %{"key" => key_params}, socket) do
    user = socket.assigns[:current_user_struct] || session_user_via_assigns(socket)

    with {:ok, key} <- owned_api_key(socket.assigns[:editing_key_id], socket),
         {:ok, workspace_ids} <- parse_key_workspaces(key_params) do
      case Dran.Accounts.replace_api_key_workspaces(key, workspace_ids, user) do
        {:ok, _key} ->
          {:noreply,
           socket
           |> assign(api_keys: current_api_keys(socket), editing_key_id: nil, edit_key_form: nil)
           |> put_flash(:info, gettext("API key access updated"))}

        {:error, :workspace_not_allowed} ->
          {:noreply,
           put_flash(socket, :error, gettext("You can only grant access to your own workspaces"))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Could not update the access"))}
      end
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Not authorized."))}
    end
  end

  # R/W ↔ R/O toggle per key: flips EVERY row the key has (a key with mixed
  # levels normalizes to the toggled state), keeping per-workspace granularity
  # reachable through the edit modal.
  @impl true
  def handle_event("toggle_write_access", %{"id" => key_id}, socket) do
    with {:ok, key} <- owned_api_key(key_id, socket) do
      key = Dran.Repo.preload(key, :api_key_workspaces)
      currently_write? = Dran.Accounts.ApiKey.write_access?(key)

      workspace_ids =
        Enum.map(key.api_key_workspaces, fn akw ->
          {akw.workspace_id, if(currently_write?, do: "read", else: "write")}
        end)

      case Dran.Accounts.replace_api_key_workspaces(
             key,
             workspace_ids,
             session_user_via_assigns(socket)
           ) do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign(api_keys: current_api_keys(socket))
           |> put_flash(:info, gettext("API key access updated"))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Could not update the access"))}
      end
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Not authorized."))}
    end
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
      _ -> {:noreply, put_flash(socket, :error, gettext("Not authorized."))}
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
      _ -> {:noreply, put_flash(socket, :error, gettext("Not authorized."))}
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
      _ -> {:noreply, put_flash(socket, :error, gettext("Not authorized."))}
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
      _ -> {:noreply, put_flash(socket, :error, gettext("Not authorized."))}
    end
  end

  @impl true
  def handle_event("copy_api_key_prefix", %{"id" => id}, socket) do
    # Same ownership guard as the other key handlers — the id is client
    # forjable, and the clipboard event would leak another user's prefix.
    with {:ok, key} <- owned_api_key(id, socket) do
      {:noreply, push_event(socket, "copy_to_clipboard", %{text: key.token_prefix})}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Not authorized."))}
    end
  end

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

  # ── Language ──────────────────────────────────────────────────────────────
  #
  # The preference is durable (users.locale). Changing it changes the language
  # of *every* string on the page — including the ones inside the layout and
  # the components, which LiveView's in-place diffing does not always carry —
  # so the honest move is to remount: `push_navigate` to this same tab makes
  # the LiveView mount again, read `users.locale` and render the whole page in
  # the new language. The flash is translated after the switch, so it lands in
  # the language the user just picked.
  @impl true
  def handle_event("save_locale", %{"locale" => %{"locale" => locale}}, socket) do
    case Dran.Accounts.update_locale(socket.assigns.current_user_struct, locale) do
      {:ok, updated_user} ->
        Gettext.put_locale(DranWeb.Gettext, updated_user.locale)

        {:noreply,
         socket
         |> assign(
           current_user_struct: updated_user,
           locale: updated_user.locale,
           locale_form: locale_form(updated_user.locale)
         )
         |> put_flash(:info, gettext("Language updated"))
         |> push_navigate(to: ~p"/settings/account")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Could not save the preference"))}
    end
  end

  # One-field form driving the language select. Values are the locale codes the
  # app ships catalogs for; the labels stay in their own language on purpose.
  defp locale_form(locale) do
    to_form(%{"locale" => locale || DranWeb.Gettext.app_default_locale()}, as: :locale)
  end

  defp locale_options do
    Enum.map(DranWeb.Gettext.supported_locales(), fn
      "en" -> {"English", "en"}
      "es" -> {"Español", "es"}
      other -> {other, other}
    end)
  end

  # Form params for the workspace×level matrix modals. `key` (optional) is
  # the existing key whose current state seeds the form (edit modal). The key
  # NAME is the agent identity (W3): entered on create, shown read-only on
  # edit — the row is the credential's identity and renaming it is out of
  # scope here (revoke + recreate is the explicit path).
  defp key_form(workspaces, key \\ nil) do
    current =
      case key do
        nil -> %{}
        key -> Map.new(key.api_key_workspaces, fn akw -> {akw.workspace_id, akw.access_level} end)
      end

    %{
      "name" => key && key.name,
      "workspaces" =>
        Map.new(workspaces, fn ws ->
          {ws.id,
           %{"enabled" => Map.has_key?(current, ws.id), "level" => current[ws.id] || "read"}}
        end)
    }
  end

  # Extracts the checked workspace×level matrix from the modal's params
  # shape: %{"workspaces" => %{id => %{"enabled" => "true", "level" => "write"}}}
  defp parse_key_workspaces(%{"workspaces" => ws_params}) do
    workspace_ids =
      ws_params
      |> Enum.filter(fn {_wid, cfg} -> is_map(cfg) and cfg["enabled"] in [true, "true"] end)
      |> Enum.map(fn {wid, cfg} ->
        level = if cfg["level"] == "write", do: "write", else: "read"
        {wid, level}
      end)

    {:ok, workspace_ids}
  end

  defp parse_key_workspaces(_), do: {:error, :invalid_params}

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
      sidebar={false}
      topbar
      topbar_active={:account}
    >
      <div class="flex-1 overflow-y-auto">
        <div class="w-full space-y-6">
          <div class="flex items-center gap-1 border-b border-base-300">
            <.tab_link active={@active_tab == :account} to={~p"/settings/account"}>
              {gettext("Account")}
            </.tab_link>
            <.tab_link active={@active_tab == :api_keys} to={~p"/settings/api-keys"}>
              {gettext("API keys")}
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
                title={gettext("Language")}
                caption={gettext("Interface language for your account.")}
                icon="hero-language"
              >
                <.form
                  for={@locale_form}
                  id="locale-form"
                  phx-change="save_locale"
                  class="space-y-3"
                >
                  <.input
                    field={@locale_form[:locale]}
                    type="select"
                    label={gettext("Language")}
                    options={locale_options()}
                    class="w-full sm:max-w-xs"
                  />
                  <p class="text-xs text-base-content/60">
                    {gettext(
                      "English is the default. Your choice is saved to your account and applies to every workspace."
                    )}
                  </p>
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
            <.api_keys_tab
              api_keys={@api_keys}
              api_key_workspaces={@api_key_workspaces}
              revealed_api_key={@revealed_api_key}
              show_create_key_modal={@show_create_key_modal}
              create_key_form={@create_key_form}
              editing_key_id={@editing_key_id}
              edit_key_form={@edit_key_form}
            />
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

  attr :api_keys, :list, required: true
  attr :api_key_workspaces, :list, default: []
  attr :revealed_api_key, :map, default: nil
  attr :show_create_key_modal, :any, default: nil
  attr :create_key_form, :map, default: nil
  attr :editing_key_id, :any, default: nil
  attr :edit_key_form, :map, default: nil

  defp api_keys_tab(assigns) do
    ~H"""
    <div id="api-keys-tab" class="space-y-6">
      <div class="flex items-start justify-between gap-4">
        <div>
          <h1 class="text-title">{gettext("API keys")}</h1>
          <p class="text-caption mt-1">
            {gettext(
              "Each key carries its own name — that name is the agent identity used to attribute what it writes — plus its own workspace access matrix (read, or read + write)."
            )}
          </p>
        </div>

        <button
          type="button"
          id="new-api-key-btn"
          phx-click="open_create_key_modal"
          class="btn btn-primary btn-sm gap-1.5"
        >
          <.icon name="hero-plus" class="size-4" />
          {gettext("New API key")}
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

      <div :if={@api_keys == []} class="text-center text-base-content/50 py-6">
        {gettext("No API keys yet — create one to give an agent access to your workspaces.")}
      </div>

      <div :if={@api_keys != []} class="overflow-x-auto">
        <table class="table table-sm">
          <thead>
            <tr>
              <th>{gettext("Name")}</th>
              <th>{gettext("Key")}</th>
              <th>{gettext("Workspaces")}</th>
              <th>{gettext("Status")}</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={key <- @api_keys} id={"api-key-#{key.id}"}>
              <td class="font-medium">{key.name}</td>
              <td>
                <div class="flex items-center gap-1">
                  <code class="text-xs">{key.token_prefix}••••</code>
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
                <div class="flex items-center gap-1.5 flex-wrap">
                  <span
                    class="badge badge-sm font-mono"
                    title={
                      Enum.map_join(
                        key.api_key_workspaces,
                        ", ",
                        &"#{&1.workspace.name}: #{access_label(&1.access_level)}"
                      )
                    }
                  >
                    <.icon name="hero-square-3-stack-3d" class="size-3 mr-1" />
                    {ngettext(
                      "%{count} workspace",
                      "%{count} workspaces",
                      length(key.api_key_workspaces)
                    )}
                  </span>
                  <%= if write_access?(key) do %>
                    <span class="badge badge-primary badge-sm">{gettext("R/W")}</span>
                  <% else %>
                    <span class="badge badge-ghost badge-sm">{gettext("R/O")}</span>
                  <% end %>
                  <button
                    type="button"
                    phx-click="edit_api_key"
                    phx-value-id={key.id}
                    class="btn btn-ghost btn-xs p-1"
                    title={gettext("Configure workspaces and levels")}
                  >
                    <.icon name="hero-adjustments-horizontal" class="size-4" />
                  </button>
                  <button
                    :if={key.api_key_workspaces != []}
                    type="button"
                    phx-click="toggle_write_access"
                    phx-value-id={key.id}
                    class="btn btn-ghost btn-xs p-1"
                    title={
                      if write_access?(key),
                        do: gettext("Switch to read only"),
                        else: gettext("Switch to read + write")
                    }
                  >
                    <.icon name="hero-arrows-right-left" class="size-4" />
                  </button>
                </div>
              </td>
              <td>
                <%= if key.revoked_at do %>
                  <span class="badge badge-error badge-sm">{gettext("Revoked")}</span>
                <% else %>
                  <span class="badge badge-success badge-sm">{gettext("Active")}</span>
                <% end %>
              </td>
              <td>
                <div class="flex items-center gap-1 justify-end">
                  <button
                    :if={is_nil(key.revoked_at)}
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
                    :if={is_nil(key.revoked_at)}
                    type="button"
                    phx-click="revoke_api_key"
                    phx-value-id={key.id}
                    data-confirm={gettext("Revoke this key? It stops working immediately.")}
                    class="btn btn-ghost btn-xs p-1 text-error"
                    title={gettext("Revoke")}
                  >
                    <.icon name="hero-no-symbol" class="size-4" />
                  </button>
                  <button
                    :if={key.revoked_at}
                    type="button"
                    phx-click="restore_api_key"
                    phx-value-id={key.id}
                    class="btn btn-ghost btn-xs p-1"
                    title={gettext("Restore")}
                  >
                    <.icon name="hero-arrow-uturn-left" class="size-4" />
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

      <%!-- Create key: name + workspace×level matrix --%>
      <.modal
        :if={@show_create_key_modal && @create_key_form}
        id="create-key-modal"
        show={true}
        title={gettext("Create API key")}
        on_close="close_create_key_modal"
        max_w="max-w-2xl"
      >
        <.key_access_form
          id="create-key-form"
          form={@create_key_form}
          workspaces={@api_key_workspaces}
          submit_event="create_api_key"
          submit_label={gettext("Create key")}
          name_mode={:editable}
        />
      </.modal>

      <%!-- Edit key access matrix --%>
      <.modal
        :if={@editing_key_id && @edit_key_form}
        id="edit-key-modal"
        show={true}
        title={gettext("Workspaces and levels")}
        on_close="close_edit_key_modal"
        max_w="max-w-2xl"
      >
        <.key_access_form
          id="edit-key-form"
          form={@edit_key_form}
          workspaces={@api_key_workspaces}
          submit_event="update_api_key_access"
          submit_label={gettext("Save")}
          name_mode={:readonly}
        />
      </.modal>
    </div>
    """
  end

  # ── Key access matrix form (create + edit modals) ─────────────────────────

  attr :id, :string, required: true
  attr :form, :map, required: true
  attr :workspaces, :list, required: true
  attr :submit_event, :string, required: true
  attr :submit_label, :string, required: true
  attr :name_mode, :atom, default: :editable

  defp key_access_form(assigns) do
    ~H"""
    <form id={@id} phx-submit={@submit_event} class="space-y-4">
      <div>
        <p class="text-sm font-medium mb-1">{gettext("Name")}</p>
        <p class="text-caption mb-3">
          {gettext(
            "The key name is the agent identity: content written with this key is attributed to this name unless the client sends an X-Hermes-Agent header."
          )}
        </p>
        <input
          :if={@name_mode == :editable}
          type="text"
          name="key[name]"
          value={@form["name"]}
          required
          placeholder={gettext("e.g. hermes-agent or backup-script")}
          class="input input-bordered input-sm w-full"
        />
        <input
          :if={@name_mode == :readonly}
          type="text"
          value={@form["name"]}
          disabled
          class="input input-bordered input-sm w-full"
        />
      </div>

      <div>
        <p class="text-sm font-medium mb-1">{gettext("Workspaces")}</p>
        <p class="text-caption mb-3">
          {gettext(
            "Tick the ones this key may access and set the level per workspace. The agent picks its memory workspace locally in its Hermes config."
          )}
        </p>
        <div class="space-y-2 max-h-72 overflow-y-auto pr-1">
          <div :for={ws <- @workspaces} class="flex items-center gap-3">
            <label class="flex items-center gap-2 cursor-pointer flex-1 min-w-0">
              <input
                type="checkbox"
                name={"key[workspaces][#{ws.id}][enabled]"}
                value="true"
                checked={@form["workspaces"][ws.id]["enabled"] == true}
                class="checkbox checkbox-sm checkbox-secondary"
              />
              <span class="text-sm truncate">{ws.name}</span>
            </label>
            <select
              name={"key[workspaces][#{ws.id}][level]"}
              class="select select-bordered select-xs"
            >
              <option value="read" selected={@form["workspaces"][ws.id]["level"] != "write"}>
                {gettext("Read only")}
              </option>
              <option value="write" selected={@form["workspaces"][ws.id]["level"] == "write"}>
                {gettext("Read + write")}
              </option>
            </select>
          </div>
        </div>
        <p :if={@workspaces == []} class="text-sm text-base-content/60">
          {gettext("You are not a member of any workspace yet.")}
        </p>
      </div>

      <div class="flex justify-end gap-2 pt-2">
        <button
          type="button"
          phx-click={
            if @submit_event == "create_api_key",
              do: "close_create_key_modal",
              else: "close_edit_key_modal"
          }
          class="btn btn-ghost btn-sm"
        >
          {gettext("Cancel")}
        </button>
        <button type="submit" class="btn btn-primary btn-sm">
          {@submit_label}
        </button>
      </div>
    </form>
    """
  end

  # Template helpers ─────────────────────────────────────────────────────────

  defp access_label("write"), do: gettext("R/W")
  defp access_label(_), do: gettext("R/O")

  # A key with ANY write row is R/W; an empty matrix is R/O.
  defp write_access?(%{api_key_workspaces: workspaces}) when workspaces != [] do
    Enum.any?(workspaces, &(&1.access_level == "write"))
  end

  defp write_access?(_), do: false

  # ── API Keys section ──────────────────────────────────────────────────────

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
