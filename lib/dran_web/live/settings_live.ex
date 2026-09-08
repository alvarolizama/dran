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
        revealed_api_key: nil,
        managed_actors: [],
        create_actor_form: to_form(%{}, as: :actor, id: "create-actor"),
        edit_actor_form: to_form(%{}, as: :actor, id: "edit-actor"),
        editing_actor_id: nil,
        actor_delete_confirmation: nil,
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

  defp apply_tab(socket, :agents, _params) do
    socket
    |> assign(active_tab: :agents, page_title: gettext("Agents"))
    |> assign(
      managed_actors: managed_actors_with_key_counts(),
      create_actor_form: to_form(%{}, as: :actor, id: "create-actor"),
      edit_actor_form: to_form(%{}, as: :actor, id: "edit-actor"),
      editing_actor_id: nil,
      actor_delete_confirmation: nil
    )
  end

  defp apply_tab(socket, _action, _params) do
    socket
    |> assign(active_tab: :agents, page_title: gettext("Agents"))
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

  @impl true
  def handle_event("revoke_api_key", %{"id" => id}, socket) do
    with {:ok, key} <- owned_api_key(id, socket),
         {:ok, _} <- Dran.Accounts.revoke_api_key(key) do
      {:noreply,
       socket
       |> assign(
         api_keys: current_api_keys(socket),
         managed_actors: managed_actors_with_key_counts()
       )
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
       |> assign(
         api_keys: current_api_keys(socket),
         managed_actors: managed_actors_with_key_counts()
       )
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
       |> assign(
         api_keys: current_api_keys(socket),
         managed_actors: managed_actors_with_key_counts()
       )
       |> put_flash(:info, gettext("API key deleted"))}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("No autorizado."))}
    end
  end

  @impl true
  def handle_event("copy_api_key_prefix", %{"id" => id}, socket) do
    # Same ownership guard as the other key handlers — the id is client
    # forjable, and the clipboard event would leak another user's prefix.
    with {:ok, key} <- owned_api_key(id, socket) do
      {:noreply, push_event(socket, "copy_to_clipboard", %{text: key.token_prefix})}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("No autorizado."))}
    end
  end

  # ── Agents tab (UI) ──────────────────────────────────────────────────────────────

  @impl true
  def handle_event("create_actor", %{"actor" => params}, socket) do
    attrs = %{
      "name" => params["name"] |> to_string() |> String.trim(),
      "kind" => "agent",
      "display_name" => normalize_optional(params["display_name"]),
      "host" => normalize_optional(params["host"])
    }

    case Dran.Actors.create_actor(attrs) do
      {:ok, _actor} ->
        {:noreply,
         socket
         |> assign(
           managed_actors: managed_actors_with_key_counts(),
           create_actor_form: to_form(%{}, as: :actor, id: "create-actor")
         )
         |> put_flash(:info, gettext("Agent created"))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(create_actor_form: to_form(changeset, as: :actor, id: "create-actor"))
         |> put_flash(:error, gettext("Could not create the agent"))}
    end
  end

  @impl true
  def handle_event("create_agent_key", %{"id" => actor_id}, socket) do
    user = socket.assigns[:current_user_struct] || session_user_via_assigns(socket)

    # una key por agente: si ya tiene una activa, no se crea otra
    actor =
      managed_actors_with_key_counts()
      |> Enum.find(&(&1.id == actor_id))

    cond do
      is_nil(actor) ->
        {:noreply, put_flash(socket, :error, gettext("Agent not found"))}

      active_agent_key(actor) ->
        {:noreply, put_flash(socket, :error, gettext("This agent already has an active key"))}

      true ->
        workspace_ids =
          socket.assigns.api_key_workspaces
          |> Enum.map(&{&1.id, "read"})

        attrs = %{
          name: actor.name,
          workspace_ids: workspace_ids,
          created_by_user_id: user && user.id,
          actor_id: actor.id
        }

        case Dran.Accounts.create_api_key(attrs) do
          {:ok, key} ->
            {:noreply,
             socket
             |> assign(
               managed_actors: managed_actors_with_key_counts(),
               revealed_api_key: %{id: key.id, token: key.token}
             )
             |> put_flash(
               :info,
               gettext("API key created — copy it now, it won't be shown again")
             )}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Could not create the API key"))}
        end
    end
  end

  @impl true
  def handle_event("edit_actor", %{"id" => id}, socket) do
    actor = Dran.Repo.get!(Dran.Actors.Actor, id)

    {:noreply,
     socket
     |> assign(editing_actor_id: actor.id)
     |> assign(
       edit_actor_form:
         to_form(
           %{"display_name" => actor.display_name || "", "host" => actor.host || ""},
           as: :actor,
           id: "edit-actor"
         )
     )}
  end

  @impl true
  def handle_event("cancel_edit_actor", _params, socket) do
    {:noreply,
     socket
     |> assign(
       editing_actor_id: nil,
       edit_actor_form: to_form(%{}, as: :actor, id: "edit-actor")
     )}
  end

  @impl true
  def handle_event("update_actor", %{"actor" => params}, socket) do
    actor = Dran.Repo.get!(Dran.Actors.Actor, socket.assigns.editing_actor_id)

    attrs = %{
      "display_name" => normalize_optional(params["display_name"]),
      "host" => normalize_optional(params["host"])
    }

    case Dran.Actors.update_actor(actor, attrs) do
      {:ok, _actor} ->
        {:noreply,
         socket
         |> assign(
           managed_actors: managed_actors_with_key_counts(),
           editing_actor_id: nil,
           edit_actor_form: to_form(%{}, as: :actor, id: "edit-actor")
         )
         |> put_flash(:info, gettext("Agent updated"))}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Could not update the agent"))}
    end
  end

  @impl true
  def handle_event("confirm_delete_actor", %{"id" => id}, socket) do
    actor = Dran.Repo.get!(Dran.Actors.Actor, id)
    counts = Dran.Actors.attribution_count(actor)

    {:noreply, assign(socket, actor_delete_confirmation: %{actor_id: actor.id, counts: counts})}
  end

  @impl true
  def handle_event("cancel_delete_actor", _params, socket) do
    {:noreply, assign(socket, actor_delete_confirmation: nil)}
  end

  @impl true
  def handle_event("delete_actor", %{"id" => id}, socket) do
    actor = Dran.Repo.get!(Dran.Actors.Actor, id)

    case Dran.Actors.delete_actor(actor) do
      {:ok, _actor} ->
        {:noreply,
         socket
         |> assign(
           managed_actors: managed_actors_with_key_counts(),
           actor_delete_confirmation: nil
         )
         |> put_flash(:info, gettext("Agent deleted"))}

      {:error, :actor_has_api_keys} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("This actor still has API keys — revoke or delete them first")
         )}

      {:error, :system_actor} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("System actors are code-managed and cannot be deleted")
         )}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Could not delete the actor"))}
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

  # The agent's single active (non-revoked) API key, if any.
  defp active_agent_key(%{api_keys: keys}) do
    Enum.find(keys, &is_nil(&1.revoked_at))
  end

  # Managed AGENTS with their api_keys preloaded, so the Agents tab can show
  # how many keys each one has without touching the Actors context.
  defp managed_actors_with_key_counts do
    Dran.Actors.list_managed_actors()
    |> Dran.Repo.preload(:api_keys)
  end

  # Empty string -> nil for optional text fields.
  defp normalize_optional(nil), do: nil

  defp normalize_optional(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
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
            <.tab_link active={@active_tab == :agents} to={~p"/settings/agents"}>
              {gettext("Agents")}
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
            <%= if @active_tab == :agents do %>
              <.agents_tab
                managed_actors={@managed_actors}
                create_actor_form={@create_actor_form}
                edit_actor_form={@edit_actor_form}
                editing_actor_id={@editing_actor_id}
                actor_delete_confirmation={@actor_delete_confirmation}
                api_key_workspaces={@api_key_workspaces}
                revealed_api_key={@revealed_api_key}
              />
            <% end %>
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

  attr :managed_actors, :list, required: true
  attr :create_actor_form, :map, required: true
  attr :edit_actor_form, :map, required: true
  attr :editing_actor_id, :any, default: nil
  attr :actor_delete_confirmation, :map, default: nil
  attr :api_key_workspaces, :list, default: []
  attr :revealed_api_key, :map, default: nil

  defp agents_tab(assigns) do
    ~H"""
    <div id="agents-tab" class="space-y-6">
      <div>
        <h1 class="text-title">{gettext("Agents")}</h1>
        <p class="text-caption mt-1">
          {gettext(
            "Agent identities for API/MCP access with their own API keys. Human users become actors automatically on login — they are not managed here."
          )}
        </p>
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

      <.section title={gettext("Create agent")} icon="hero-user-plus">
        <.form
          for={@create_actor_form}
          id="create-actor-form"
          phx-submit="create_actor"
          class="space-y-4"
        >
          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <.input
              field={@create_actor_form[:name]}
              label={gettext("Name")}
              placeholder={gettext("e.g. hermes-agent or backup-script")}
              required
            />
            <.input
              field={@create_actor_form[:display_name]}
              label={gettext("Display name")}
              placeholder={gettext("Optional — shown instead of the name")}
            />
            <.input
              field={@create_actor_form[:host]}
              label={gettext("Host")}
              placeholder={gettext("Optional — e.g. laptop or ci-runner")}
            />
          </div>
          <button type="submit" class="btn btn-primary btn-sm" phx-disable-with={gettext("Saving…")}>
            {gettext("Create agent")}
          </button>
        </.form>
      </.section>

      <.section :if={@managed_actors != []} title={gettext("Existing agents")} icon="hero-users">
        <div class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>{gettext("Name")}</th>
                <th>{gettext("Display name")}</th>
                <th>{gettext("Host")}</th>
                <th>{gettext("API key")}</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={actor <- @managed_actors} id={"actor-#{actor.id}"}>
                <td class="font-medium">{actor.name}</td>
                <td>{actor.display_name || "—"}</td>
                <td>{actor.host || "—"}</td>
                <td>
                  <div class="flex items-center gap-1">
                    <%= if active_key = active_agent_key(actor) do %>
                      <code class="text-xs">{active_key.token_prefix}••••</code>
                      <button
                        type="button"
                        phx-click="copy_api_key_prefix"
                        phx-value-id={active_key.id}
                        class="btn btn-ghost btn-xs p-1"
                        title={gettext("Copy prefix")}
                      >
                        <.icon name="hero-clipboard-document" class="size-3.5" />
                      </button>
                      <button
                        type="button"
                        phx-click="toggle_write_access"
                        phx-value-id={active_key.id}
                        class="btn btn-ghost btn-xs p-1"
                        title={
                          if Dran.Accounts.ApiKey.write_access?(active_key),
                            do: gettext("Click to make read-only"),
                            else: gettext("Click to enable write access")
                        }
                      >
                        <%= if Dran.Accounts.ApiKey.write_access?(active_key) do %>
                          <span class="badge badge-primary badge-sm">{gettext("R/W")}</span>
                        <% else %>
                          <span class="badge badge-ghost badge-sm">{gettext("R/O")}</span>
                        <% end %>
                      </button>
                      <button
                        type="button"
                        phx-click="regenerate_api_key"
                        phx-value-id={active_key.id}
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
                        phx-click="revoke_api_key"
                        phx-value-id={active_key.id}
                        data-confirm={gettext("Revoke this key? It stops working immediately.")}
                        class="btn btn-ghost btn-xs p-1 text-error"
                        title={gettext("Revoke")}
                      >
                        <.icon name="hero-no-symbol" class="size-4" />
                      </button>
                    <% else %>
                      <button
                        type="button"
                        phx-click="create_agent_key"
                        phx-value-id={actor.id}
                        class="btn btn-outline btn-xs gap-1"
                      >
                        <.icon name="hero-key" class="size-3.5" />
                        {gettext("Create key")}
                      </button>
                    <% end %>
                  </div>
                </td>
                <td>
                  <div class="flex items-center gap-1 justify-end">
                    <button
                      type="button"
                      phx-click="edit_actor"
                      phx-value-id={actor.id}
                      class="btn btn-ghost btn-xs p-1"
                      title={gettext("Edit")}
                    >
                      <.icon name="hero-pencil-square" class="size-4" />
                    </button>
                    <button
                      type="button"
                      phx-click="confirm_delete_actor"
                      phx-value-id={actor.id}
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

      <div :if={@managed_actors == []} class="text-center text-base-content/50 py-6">
        {gettext("No agents yet — create one with the form above.")}
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

      <%!-- Inline edit (display_name / host) --%>
      <.modal
        id="edit-actor-modal"
        show={@editing_actor_id != nil}
        title={gettext("Edit actor")}
        on_close="cancel_edit_actor"
      >
        <.form for={@edit_actor_form} id="edit-actor-form" phx-submit="update_actor" class="space-y-4">
          <.input
            field={@edit_actor_form[:display_name]}
            label={gettext("Display name")}
            placeholder={gettext("Optional — shown instead of the name")}
          />
          <.input
            field={@edit_actor_form[:host]}
            label={gettext("Host")}
            placeholder={gettext("Optional — e.g. laptop or ci-runner")}
          />
          <div class="flex justify-end gap-2 pt-2">
            <button type="button" phx-click="cancel_edit_actor" class="btn btn-ghost btn-sm">
              {gettext("Cancel")}
            </button>
            <button type="submit" class="btn btn-primary btn-sm" phx-disable-with={gettext("Saving…")}>
              {gettext("Save")}
            </button>
          </div>
        </.form>
      </.modal>

      <%!-- Inline delete confirmation with attribution impact --%>
      <div
        :if={@actor_delete_confirmation}
        class="card bg-error/10 border border-error/40"
        id="actor-delete-confirmation"
      >
        <div class="card-body py-4 space-y-3">
          <h3 class="font-semibold text-error flex items-center gap-2">
            <.icon name="hero-exclamation-triangle" class="size-5" />
            {gettext("Delete this actor?")}
          </h3>
          <p class="text-sm text-base-content/80">
            {gettext("Work attributed to this actor:")}

            {ngettext(
              "%{count} page",
              "%{count} pages",
              @actor_delete_confirmation.counts.pages
            )} · {ngettext(
              "%{count} memory",
              "%{count} memories",
              @actor_delete_confirmation.counts.memories
            )}
          </p>
          <div class="flex justify-end gap-2">
            <button type="button" phx-click="cancel_delete_actor" class="btn btn-ghost btn-sm">
              {gettext("Cancel")}
            </button>
            <button
              type="button"
              phx-click="delete_actor"
              phx-value-id={@actor_delete_confirmation.actor_id}
              class="btn btn-error btn-sm"
            >
              {gettext("Delete actor")}
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

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
