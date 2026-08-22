defmodule DranWeb.AdminUsersLive do
  @moduledoc """
  Admin user management (owner-only). Mirrors the old SettingsLive "users"
  tab: list users, create (email + name + assign to workspaces), delete,
  toggle workspace membership, set the default workspace, copy a user's API
  token, and impersonate. The impersonation route/controller lands in F6.
  """

  use DranWeb, :live_view

  import DranWeb.Admin

  alias DranWeb.Plugs.Auth

  @impl true
  def mount(_params, session, socket) do
    {socket, _context} = Auth.assign_to_socket(socket, session)

    socket =
      socket
      |> assign(active_nav: "admin", page_title: gettext("Usuarios"), workspace_slug: nil)
      |> assign_users()
      |> assign_workspaces()
      |> assign(
        user_form: to_form(%{}, as: :user),
        editing_user: nil,
        form_workspace_ids: [],
        show_user_modal: false,
        modal_title: gettext("Add User"),
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

  @impl true
  def handle_event("new_user", _params, socket) do
    {:noreply,
     assign(socket,
       editing_user: nil,
       user_form: to_form(%{}, as: :user),
       form_workspace_ids: [],
       modal_title: gettext("Add User"),
       show_user_modal: true
     )}
  end

  @impl true
  def handle_event("edit_user", %{"id" => id}, socket) do
    user = Dran.Accounts.get_user!(id)
    ids = Enum.map(user.workspaces, & &1.id)

    {:noreply,
     assign(socket,
       editing_user: user,
       user_form: to_form(%{email: user.email, name: user.name}, as: :user),
       form_workspace_ids: ids,
       modal_title: gettext("Edit User"),
       show_user_modal: true
     )}
  end

  @impl true
  def handle_event("close_user_modal", _params, socket) do
    {:noreply, assign(socket, show_user_modal: false)}
  end

  @impl true
  def handle_event("save_user", %{"user" => params}, socket) do
    email = params["email"] || ""
    name = params["name"] || ""
    ws_ids = params |> Map.get("workspace_ids", []) |> List.wrap()

    case save_user(socket.assigns.editing_user, %{email: email, name: name}, ws_ids) do
      {:ok, label} ->
        {:noreply,
         socket
         |> assign_users()
         |> assign(show_user_modal: false)
         |> put_flash(:info, gettext("User saved: %{email}", email: label))}

      {:error, changeset} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Could not save user: %{errors}", errors: inspect(changeset.errors))
         )}
    end
  end

  @impl true
  def handle_event("delete_user", %{"id" => id}, socket) do
    user = Dran.Accounts.get_user!(id)

    case Dran.Accounts.delete_user(user) do
      {:ok, _} ->
        socket
        |> assign_users()
        |> put_flash(:info, gettext("User deleted"))

      {:error, _} ->
        put_flash(socket, :error, gettext("Could not delete user"))
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

  defp save_user(nil, attrs, ws_ids) do
    with {:ok, user} <- Dran.Accounts.create_user(attrs) do
      for id <- ws_ids do
        Dran.Accounts.add_user_to_workspace(user, Dran.Knowledge.get_workspace!(id))
      end

      {:ok, user.email}
    end
  end

  defp save_user(user, attrs, ws_ids) do
    with {:ok, user} <- Dran.Accounts.update_user(user, attrs) do
      for ws <- Dran.Knowledge.list_workspaces() do
        is_member = Dran.Accounts.user_in_workspace?(user, ws)
        wanted = to_string(ws.id) in ws_ids

        cond do
          wanted and not is_member -> Dran.Accounts.add_user_to_workspace(user, ws)
          not wanted and is_member -> Dran.Accounts.remove_user_from_workspace(user, ws)
          true -> :ok
        end
      end

      {:ok, user.email}
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
      <div class="flex-1 overflow-y-auto" id="users-tab" phx-hook=".CopyUserToken">
        <div class="w-full p-6 space-y-6">
          <div class="flex items-center justify-between">
            <div>
              <h1 class="text-title">{gettext("Users")}</h1>
              <p class="text-caption mt-1">{gettext("Manage users and their workspace access.")}</p>
            </div>
            <button phx-click="new_user" class="btn btn-primary btn-sm gap-1.5">
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
          <.section :if={@users != []} title={gettext("Usuarios")} icon="hero-users">
            <div class="overflow-x-auto">
              <table class="table table-sm">
                <thead>
                  <tr>
                    <th>{gettext("Email")}</th>
                    <th>{gettext("Nombre")}</th>
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
                      <span :if={user.is_owner} class="badge badge-primary badge-sm">
                        {gettext("Admin")}
                      </span>
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
                        <button
                          phx-click="edit_user"
                          phx-value-id={user.id}
                          class="btn btn-ghost btn-xs p-1"
                          title={gettext("Edit")}
                        >
                          <.icon name="hero-pencil" class="size-4" />
                        </button>
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
                            class="btn btn-ghost btn-xs p-1 text-base-content/40"
                            title={gettext("Impersonate (available in a later update)")}
                          >
                            <.icon name="hero-user" class="size-3.5" />
                          </button>
                        </form>
                        <button
                          phx-click="delete_user"
                          phx-value-id={user.id}
                          data-confirm={gettext("Delete this user?")}
                          class="btn btn-ghost btn-xs p-1 text-error"
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

          <div :if={@users == []} class="text-center text-base-content/50 py-6">
            {gettext("No users yet — create one with the button above.")}
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

      <%!-- Add / edit user modal --%>
      <.modal id="user-modal" show={@show_user_modal} title={@modal_title} on_close="close_user_modal">
        <.form for={@user_form} phx-submit="save_user" class="space-y-4">
          <div class="grid grid-cols-2 gap-3">
            <.input field={@user_form[:email]} label={gettext("Email")} type="email" required />
            <.input field={@user_form[:name]} label={gettext("Nombre")} />
          </div>

          <div>
            <label class="text-sm font-medium">{gettext("Contexts")}</label>
            <div class="flex flex-wrap gap-2 mt-2">
              <label :for={ctx <- @all_workspaces} class="flex items-center gap-2">
                <input
                  type="checkbox"
                  name="user[workspace_ids][]"
                  value={ctx.id}
                  checked={Enum.any?(@form_workspace_ids, &(&1 == ctx.id))}
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
    </Layouts.app>
    """
  end
end
