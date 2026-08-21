defmodule DranWeb.AdminUsersLive do
  @moduledoc """
  Admin user management (owner-only). Mirrors the old SettingsLive "users"
  tab: list users, create (email + name + assign to workspaces), delete,
  toggle workspace membership, set the default workspace, copy a user's API
  token, and impersonate. The impersonation route/controller lands in F6.
  """

  use DranWeb, :live_view

  alias DranWeb.Plugs.Auth

  @impl true
  def mount(_params, session, socket) do
    {socket, _context} = Auth.assign_to_socket(socket, session)

    socket =
      socket
      |> assign(active_nav: "admin", page_title: gettext("Usuarios"))
      |> assign_users()
      |> assign_workspaces()
      |> assign_new_user_form()
      |> assign(
        show_user_modal: false,
        wiki_google_open_signup: Dran.Settings.get("wiki_google_open_signup") == true
      )

    {:ok, socket}
  end

  defp assign_users(socket) do
    users = Dran.Accounts.list_users()
    # Group: owners first, then regular users — alphabetical within each.
    grouped =
      users
      |> Enum.group_by(fn
        %{is_owner: true} -> :owner
        _ -> :user
      end)
      |> Map.merge(%{owner: [], user: []}, fn _k, v, _default -> v end)

    assign(socket, users: grouped[:owner] ++ grouped[:user])
  end

  defp assign_workspaces(socket) do
    assign(socket, all_workspaces: Dran.Knowledge.list_workspaces())
  end

  defp assign_new_user_form(socket) do
    assign(socket, new_user_form: to_form(%{}, as: :user))
  end

  @impl true
  def handle_event("open_user_modal", _params, socket) do
    {:noreply, assign(socket, show_user_modal: true)}
  end

  @impl true
  def handle_event("close_user_modal", _params, socket) do
    {:noreply, assign(socket, show_user_modal: false)}
  end

  @impl true
  def handle_event("create_user", %{"user" => params}, socket) do
    email = Map.get(params, "email", "")
    name = Map.get(params, "name", "")
    workspace_ids = Map.get(params, "workspace_ids", []) |> List.wrap()

    case Dran.Accounts.create_user(%{email: email, name: name}) do
      {:ok, user} ->
        for workspace_id <- workspace_ids do
          context = Dran.Knowledge.get_workspace!(workspace_id)
          Dran.Accounts.add_user_to_workspace(user, context)
        end

        socket
        |> assign_users()
        |> assign_new_user_form()
        |> assign(show_user_modal: false)
        |> put_flash(:info, "User created: #{email}")

      {:error, changeset} ->
        put_flash(socket, :error, "Could not create user: #{inspect(changeset.errors)}")
    end
    |> then(&{:noreply, &1})
  end

  @impl true
  def handle_event("delete_user", %{"id" => id}, socket) do
    user = Dran.Accounts.get_user!(id)

    case Dran.Accounts.delete_user(user) do
      {:ok, _} ->
        socket
        |> assign_users()
        |> put_flash(:info, "User deleted")

      {:error, _} ->
        put_flash(socket, :error, "Could not delete user")
    end
    |> then(&{:noreply, &1})
  end

  @impl true
  def handle_event("copy_user_token", %{"id" => id}, socket) do
    user = Dran.Accounts.get_user!(id)

    if user.api_token do
      {:noreply,
       socket
       |> push_event("copy_to_clipboard", %{text: user.api_token})
       |> put_flash(:info, gettext("API token copied to clipboard."))}
    else
      {:noreply, put_flash(socket, :error, gettext("User has no API token."))}
    end
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
  def handle_event("set_default_context", %{"user_id" => id, "slug" => slug}, socket) do
    user = Dran.Accounts.get_user!(id)

    case Dran.Accounts.set_default_context(user, slug) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign_users()
         |> put_flash(:info, gettext("Default context updated"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not update default context"))}
    end
  end

  @impl true
  def handle_event("toggle_wiki_google_signup", _params, socket) do
    current = Dran.Settings.get("wiki_google_open_signup") == true
    Dran.Settings.put("wiki_google_open_signup", !current)
    {:noreply, assign(socket, wiki_google_open_signup: !current)}
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
      <div class="flex-1 overflow-y-auto" id="users-tab" phx-hook=".CopyUserToken">
        <div class="w-full p-6 space-y-6">
          <div class="flex items-center justify-between">
            <div>
              <h1 class="text-title">{gettext("Users")}</h1>
              <p class="text-caption mt-0.5">{gettext("Manage users and their workspace access.")}</p>
            </div>
            <button
              phx-click="open_user_modal"
              class="btn btn-primary btn-sm gap-1.5"
            >
              <.icon name="hero-plus" class="size-4" />
              {gettext("Add User")}
            </button>
          </div>

          <%!-- Google open signup toggle --%>
          <div
            :if={DranWeb.OAuth.Google.configured?()}
            class="card bg-base-100 border border-base-300"
          >
            <div class="card-body p-4 flex-row items-center justify-between gap-4">
              <div>
                <h3 class="text-sm font-semibold flex items-center gap-2">
                  <.icon name="hero-globe-alt" class="size-4 text-primary/70" />
                  {gettext("Google auto-signup")}
                </h3>
                <p class="text-xs text-base-content/50 mt-1">
                  {gettext(
                    "Allow anyone with a Google account to sign up and browse wikis. Users are created without context access."
                  )}
                </p>
              </div>
              <input
                type="checkbox"
                checked={@wiki_google_open_signup}
                phx-click="toggle_wiki_google_signup"
                class="toggle toggle-sm toggle-primary"
              />
            </div>
          </div>

          <%!-- Users list --%>
          <div class="card bg-base-100 border border-base-300">
            <div class="card-body">
              <h3 class="text-lg font-semibold">{gettext("Existing Users")}</h3>
              <div class="overflow-x-auto">
                <table class="table table-sm">
                  <thead>
                    <tr>
                      <th>{gettext("Email")}</th>
                      <th>{gettext("Name")}</th>
                      <th>{gettext("Admin")}</th>
                      <th>{gettext("Contexts")}</th>
                      <th>{gettext("Default context")}</th>
                      <th>{gettext("API Token")}</th>
                      <th></th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={user <- @users} id={"user-#{user.id}"}>
                      <td class="font-medium">{user.email}</td>
                      <td>{user.name}</td>
                      <td>
                        <span :if={user.is_owner} class="badge badge-primary badge-sm">Admin</span>
                      </td>
                      <td>
                        <div class="flex flex-wrap gap-1">
                          <span :for={ctx <- user.workspaces} class="badge badge-ghost badge-sm">
                            {ctx.name}
                          </span>
                        </div>
                      </td>
                      <td>
                        <form phx-change="set_default_context" id={"default-context-form-#{user.id}"}>
                          <input type="hidden" name="user_id" value={user.id} />
                          <select
                            name="slug"
                            class="select select-bordered select-xs w-full max-w-[12rem]"
                            id={"default-context-select-#{user.id}"}
                          >
                            <option value="" selected={is_nil(user.default_workspace_slug)}>
                              {gettext("— Global default —")}
                            </option>
                            <option
                              :for={ctx <- @all_workspaces}
                              value={ctx.slug}
                              selected={user.default_workspace_slug == ctx.slug}
                            >
                              {ctx.name}
                            </option>
                          </select>
                        </form>
                      </td>
                      <td>
                        <div class="flex items-center gap-1">
                          <code class="text-xs">{String.slice(user.api_token, 0, 8)}...</code>
                          <button
                            type="button"
                            phx-click="copy_user_token"
                            phx-value-id={user.id}
                            class="btn btn-ghost btn-xs p-1"
                            title={gettext("Copy token")}
                          >
                            <.icon name="hero-clipboard-document" class="size-3.5" />
                          </button>
                        </div>
                      </td>
                      <td>
                        <div class="flex items-center gap-1 justify-end">
                          <%!--
                            Impersonation lands in F6 (route + controller + banner).
                            Rendered as a disabled form action for now so nothing is
                            reachable before the route exists; F6 swaps in the real
                            POST /admin/impersonate/:id.
                          --%>
                          <form
                            action={"/admin/impersonate/#{user.id}"}
                            method="post"
                            data-confirm={gettext("Impersonate this user?")}
                          >
                            <button
                              type="submit"
                              disabled
                              class="btn btn-ghost btn-xs text-base-content/40"
                              title={gettext("Impersonate (available in a later update)")}
                            >
                              <.icon name="hero-user" class="size-3.5" />
                            </button>
                          </form>
                          <button
                            phx-click="delete_user"
                            phx-value-id={user.id}
                            data-confirm={gettext("Delete this user?")}
                            class="btn btn-ghost btn-xs text-error"
                          >
                            <.icon name="hero-trash" class="size-4" />
                          </button>
                        </div>
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </div>
          </div>

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
      </div>

      <%!-- Add user modal --%>
      <div
        :if={@show_user_modal}
        class="fixed inset-0 z-50 flex items-center justify-center bg-black/50"
      >
        <div
          class="card bg-base-100 border border-base-300 shadow-xl w-full max-w-lg"
          phx-click-away="close_user_modal"
        >
          <div class="card-body">
            <div class="flex items-center justify-between mb-2">
              <h3 class="text-lg font-semibold">{gettext("Add User")}</h3>
              <button
                phx-click="close_user_modal"
                class="btn btn-ghost btn-xs btn-circle"
              >
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </div>

            <.form for={@new_user_form} phx-submit="create_user" class="space-y-3">
              <div class="grid grid-cols-2 gap-3">
                <.input field={@new_user_form[:email]} label={gettext("Email")} type="email" required />
                <.input field={@new_user_form[:name]} label={gettext("Name")} />
              </div>

              <div>
                <label class="text-sm font-medium">{gettext("Contexts")}</label>
                <div class="flex flex-wrap gap-2 mt-2">
                  <label :for={ctx <- @all_workspaces} class="flex items-center gap-2">
                    <input
                      type="checkbox"
                      name="user[workspace_ids][]"
                      value={ctx.id}
                      class="checkbox checkbox-sm"
                    />
                    <span class="text-sm">{ctx.name}</span>
                  </label>
                </div>
              </div>

              <div class="flex justify-end gap-2 pt-2">
                <button
                  type="button"
                  phx-click="close_user_modal"
                  class="btn btn-ghost btn-sm"
                >
                  {gettext("Cancel")}
                </button>
                <button type="submit" class="btn btn-primary btn-sm">
                  {gettext("Create User")}
                </button>
              </div>
            </.form>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
