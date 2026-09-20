defmodule DranWeb.AdminUsersLive do
  @moduledoc """
  Admin user management (owner-only): list users, create (email + name +
  password), edit, grant or revoke ACCESS to the instance, delete, copy a
  user's API token, and impersonate.

  W6 (contract-instance-visibility-20260919): the per-user "default workspace"
  selector and the "may create workspaces" toggle are gone — with a single
  container neither one has anything to point at. What survives is membership
  as the ACCESS grant (the checkbox list), which is why the column says Access
  instead of the older "Contexts".
  """

  use DranWeb, :live_view

  alias DranWeb.Plugs.Auth

  @impl true
  def mount(_params, session, socket) do
    {socket, _context} = Auth.assign_to_socket(socket, session)

    socket =
      socket
      |> assign(active_nav: "admin_users", page_title: gettext("Users"), workspace_slug: nil)
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
       # Claves string: un mapa con átomos no es un formulario válido para
       # Phoenix (`to_form` avisa y lo trata como params de todos modos).
       user_form: to_form(%{"email" => user.email, "name" => user.name}, as: :user),
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
    ws_ids = params |> Map.get("workspace_ids", []) |> List.wrap()

    # `params` goes to the changeset AS IT CAME (string keys and all) on
    # purpose: Phoenix.HTML.FormData exposes a changeset's errors only when the
    # changeset carries an `action` (Repo.insert/update set it) AND
    # `Phoenix.Component.used_input?/1` finds the field in `form.params`. Both
    # are keyed by string — hand the changeset a map of atoms and the error is
    # built, dropped and never rendered, which is exactly the silent failure
    # this form used to have.
    case save_user(socket.assigns.editing_user, params, ws_ids) do
      {:ok, label} ->
        {:noreply,
         socket
         |> assign_users()
         |> assign(show_user_modal: false, editing_user: nil)
         |> put_flash(:info, gettext("User saved: %{email}", email: label))}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(
           user_form: to_form(changeset, as: :user),
           form_workspace_ids: ws_ids,
           show_user_modal: true
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
  def handle_event("toggle_wiki_google_signup", _params, socket) do
    current = Dran.Settings.get("wiki_google_open_signup") == true
    Dran.Settings.put("wiki_google_open_signup", !current)
    {:noreply, assign(socket, wiki_google_open_signup: !current)}
  end

  # Creating asks for a password (the modal renders the field, `required`) and
  # goes through `create_user_with_password/1`. `Dran.Accounts.create_user/1`
  # would happily build the row without one — and an account with no password
  # and no google_id can never sign in, so inviting that person to a workspace
  # would hand them a door with no key.
  defp save_user(nil, attrs, ws_ids) do
    with {:ok, user} <- Dran.Accounts.create_user_with_password(attrs) do
      for id <- ws_ids do
        Dran.Accounts.add_user_to_workspace(user, Dran.Knowledge.get_workspace!(id))
      end

      {:ok, user.email}
    end
  end

  # Editing goes through `update_user_as_admin/2`: the optional password field of
  # the modal is a RESET (no current password — the admin does not know it), which
  # is how an account that cannot sign in gets back in.
  defp save_user(user, attrs, ws_ids) do
    with {:ok, user} <- Dran.Accounts.update_user_as_admin(user, attrs) do
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
      user={@user}
      workspace_slug={@workspace_slug}
      active_nav={@active_nav}
      nav={:instance}
    >
      <div class="w-full" id="users-tab" phx-hook=".CopyUserToken">
        <div class="w-full space-y-6">
          <div class="flex flex-wrap items-center justify-between gap-3">
            <div>
              <h1 class="text-title">{gettext("Users")}</h1>
              <p class="text-caption mt-1">{gettext("Manage users and their workspace access.")}</p>
            </div>
            <.button phx-click="new_user" id="new-user-btn">
              <.icon name="hero-plus" class="size-4" />
              {gettext("Add User")}
            </.button>
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
          <.section :if={@users != []} title={gettext("Users")} icon="hero-users">
            <div class="overflow-x-auto">
              <table class="table table-sm">
                <thead>
                  <tr>
                    <th>{gettext("Email")}</th>
                    <th>{gettext("Name")}</th>
                    <th>{gettext("Admin")}</th>
                    <th>{gettext("Access")}</th>
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
                      <div :if={user.workspaces != []} class="flex flex-wrap gap-1">
                        <span
                          :for={ctx <- user.workspaces}
                          class="badge badge-ghost badge-sm"
                          title={gettext("This account can open the instance")}
                        >
                          {ctx.name}
                        </span>
                      </div>
                      <span :if={user.workspaces == []} class="text-base-content/40 text-xs">—</span>
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
                          id={"impersonate-#{user.id}"}
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
      <.modal :if={@show_user_modal} id="user-modal" title={@modal_title} on_close="close_user_modal">
        <.form for={@user_form} id="user-form" phx-submit="save_user" class="space-y-4">
          <div class="grid grid-cols-2 gap-3">
            <.input field={@user_form[:email]} label={gettext("Email")} type="email" required />
            <.input
              field={@user_form[:name]}
              label={gettext("Name")}
              required
            />
          </div>

          <%!--
            La contraseña se pide al CREAR (sin ella la cuenta no tiene forma de
            entrar: no hay password_hash, no hay google_id, y la invitación al
            workspace no sirve para nada) y se OFRECE al editar como reset.
            Al editar es opcional y en blanco significa "no la toques" — así el
            admin puede devolverle la entrada a una cuenta que la perdió, o
            dársela a una que nació sin ella, sin conocer la anterior.
          --%>
          <.input
            :if={is_nil(@editing_user)}
            field={@user_form[:password]}
            type="password"
            label={gettext("Password")}
            hint={gettext("Minimum 8 characters. Share it with them: it is how they sign in.")}
            autocomplete="new-password"
            required
          />

          <.input
            :if={@editing_user}
            field={@user_form[:password]}
            type="password"
            label={gettext("New password")}
            hint={
              gettext(
                "Leave it empty to keep the current one. Set it to give access back to an account that cannot sign in."
              )
            }
            autocomplete="new-password"
          />

          <div>
            <label class="text-sm font-medium">{gettext("Access")}</label>
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
              {gettext("Cancel")}
            </button>
            <button
              type="submit"
              class="btn btn-primary btn-sm"
              phx-disable-with={gettext("Guardando…")}
            >
              {gettext("Save")}
            </button>
          </div>
        </.form>
      </.modal>
    </Layouts.app>
    """
  end
end
