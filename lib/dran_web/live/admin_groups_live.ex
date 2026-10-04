defmodule DranWeb.AdminGroupsLive do
  @moduledoc """
  Group administration (W4, contract-instance-visibility-20260919).

  Instance admins create/rename/delete `user_groups` and manage their
  memberships — the share-with-group targets. Reachable at /admin/groups
  under the :admin pipeline (instance owner ∪ admin role).
  """

  use DranWeb, :live_view

  alias Dran.Accounts
  alias Dran.Sharing

  @impl true
  def mount(_params, session, socket) do
    {socket, _context} = DranWeb.Plugs.Auth.assign_to_socket(socket, session)

    socket =
      socket
      |> assign(:active_nav, "admin_groups")
      |> assign(:page_title, gettext("Groups"))
      # Instance shell (DESIGN §T2): /admin/* renders the instance nav. Without
      # this the sidebar fell back to the KNOWLEDGE nav and the whole Admin
      # group vanished on the one page that IS admin. `workspace_slug: nil`
      # mirrors the rest of /admin/* — no sidebar search box on instance pages.
      |> assign(:workspace_slug, nil)
      |> assign_groups()
      |> assign(:group_form, to_form(%{"name" => ""}, as: :group))
      |> assign(:members_group, nil)
      |> assign(:members, [])
      |> assign(:all_users, [])
      |> assign(:member_search, "")
      |> assign(:invite_form, blank_invite_form())

    {:ok, socket}
  end

  defp assign_groups(socket) do
    groups =
      Enum.map(Sharing.list_groups_with_counts(), fn {group, count} ->
        %{id: group.id, name: group.name, slug: group.slug, members: count}
      end)

    assign(socket, :groups, groups)
  end

  @impl true
  def handle_event("create_group", %{"group" => %{"name" => name}}, socket) do
    case Sharing.create_group(%{name: name}) do
      {:ok, _group} ->
        {:noreply,
         socket
         |> assign_groups()
         |> assign(:group_form, to_form(%{"name" => ""}, as: :group))
         |> put_flash(:info, gettext("Group created."))}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:group_form, to_form(changeset, as: :group))
         |> put_flash(:error, gettext("Could not create the group."))}
    end
  end

  def handle_event("delete_group", %{"id" => id}, socket) do
    group = Sharing.get_group!(String.to_integer(id))

    case Sharing.delete_group(group) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign_groups()
         |> put_flash(:info, gettext("Group deleted — its shares were removed too."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not delete the group."))}
    end
  end

  def handle_event("rename_group", %{"id" => id, "name" => name}, socket) do
    group = Sharing.get_group!(String.to_integer(id))

    case Sharing.update_group(group, %{name: name}) do
      {:ok, _} ->
        {:noreply, assign_groups(socket)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not rename the group."))}
    end
  end

  # Membership is managed inline per group row. id "0" closes the panel.
  def handle_event("manage_members", %{"id" => "0"}, socket) do
    {:noreply, assign(socket, :members_group, nil)}
  end

  def handle_event("manage_members", %{"id" => id}, socket) do
    group = Sharing.get_group!(String.to_integer(id))

    {:noreply,
     socket
     |> assign(:members_group, group)
     # Abrir (o cambiar de) grupo arranca con la búsqueda limpia: el filtro
     # pertenece al panel donde se escribió.
     |> assign(:member_search, "")
     |> assign(:invite_form, blank_invite_form())
     |> assign_members(group.id)}
  end

  # Filtro en vivo sobre la lista local de usuarios — una query por tecla no
  # hace falta. Es el mismo molde del panel de miembros del workspace
  # (`workspace_settings_live.ex`, bloque "Add users").
  def handle_event("search_members", %{"q" => q}, socket) do
    {:noreply, assign(socket, :member_search, q)}
  end

  def handle_event("add_member", %{"group_id" => group_id, "user_id" => user_id}, socket) do
    group = Sharing.get_group!(String.to_integer(group_id))
    {:ok, _} = Sharing.add_group_member(group, String.to_integer(user_id))

    {:noreply,
     socket
     |> assign_members(group.id)
     |> put_flash(:info, gettext("Membership updated"))}
  end

  # Payload incompleto o forjado: no hay a quién agregar. El select viejo tenía
  # su propia cláusula para el envío con el `user_id` vacío; sin ésta, un evento
  # sin `user_id` tira el proceso en vez de no hacer nada.
  def handle_event("add_member", _params, socket), do: {:noreply, socket}

  def handle_event("remove_member", %{"group_id" => group_id, "user_id" => user_id}, socket) do
    group = Sharing.get_group!(String.to_integer(group_id))
    :ok = Sharing.remove_group_member(group, String.to_integer(user_id))

    {:noreply,
     socket
     |> assign_members(group.id)
     |> put_flash(:info, gettext("Membership updated"))}
  end

  # El panel cerrado no tiene formulario que dispare esto; la cláusula existe
  # para que un evento viejo (o forjado) no reviente en `add_group_member_by_email/2`.
  def handle_event("invite_member", _params, %{assigns: %{members_group: nil}} = socket) do
    {:noreply, socket}
  end

  # "Invitar" significa acá lo mismo que en el panel del workspace: la cuenta ya
  # debe existir — no hay correo de invitación, la membresía entra al aceptar.
  def handle_event("invite_member", %{"invite" => params}, socket) do
    group = socket.assigns.members_group
    email = params["email"] || ""

    case Sharing.add_group_member_by_email(group, email) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:invite_form, blank_invite_form())
         |> assign_members(group.id)
         |> put_flash(:info, gettext("%{email} is now a member of this group", email: email))}

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
        {:noreply, put_flash(socket, :info, gettext("That user is already in this group."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not add the user"))}
    end
  end

  defp assign_members(socket, group_id) do
    socket
    |> assign(:members, Sharing.list_group_members(group_id))
    |> assign(:all_users, Accounts.list_users())
  end

  defp blank_invite_form, do: to_form(%{"email" => ""}, as: :invite)

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
      <div class="p-6 space-y-6 max-w-4xl">
        <div>
          <h1 class="text-title">{gettext("Groups")}</h1>
          <p class="text-caption mt-1">
            {gettext(
              "Share content with several people at once — a group is a list of users used as a share target."
            )}
          </p>
        </div>

        <.form for={@group_form} id="group-create-form" phx-submit="create_group" class="flex gap-2">
          <.input
            field={@group_form[:name]}
            type="text"
            placeholder={gettext("New group name…")}
            class="flex-1"
          />
          <button type="submit" class="btn btn-primary btn-sm">
            <.icon name="hero-plus" class="size-4" /> {gettext("Create")}
          </button>
        </.form>

        <div class="space-y-2">
          <div
            :for={group <- @groups}
            id={"group-row-#{group.id}"}
            class="surface-2 rounded-xl p-4 flex items-center justify-between gap-3"
          >
            <div class="min-w-0 space-y-1">
              <p class="font-medium truncate">{group.name}</p>
              <div class="flex items-center gap-2 flex-wrap">
                <%!-- El slug es la identidad que el cliente copia a su config
                       de agente (shaping A9/F17, P19): visible y copiable. --%>
                <code
                  id={"group-slug-#{group.id}"}
                  data-slug={group.slug}
                  class="text-caption font-mono bg-base-100 rounded-md px-2 py-0.5 border border-base-300 select-all"
                >
                  {group.slug}
                </code>
                <button
                  type="button"
                  id={"copy-group-slug-#{group.id}"}
                  data-copy-target={"group-slug-#{group.id}"}
                  phx-hook=".CopyGroupSlug"
                  class="btn btn-ghost btn-xs gap-1"
                  title={gettext("Copy the group slug")}
                >
                  <span data-copy-icon class="flex items-center gap-1">
                    <.icon name="hero-clipboard-document" class="size-3.5" />
                    {gettext("Copy")}
                  </span>
                  <span data-check-icon class="hidden items-center gap-1">
                    <.icon name="hero-clipboard-document-check" class="size-3.5" />
                    {gettext("Copied!")}
                  </span>
                </button>
                <span class="text-caption text-base-content/50">
                  {group.members} {gettext("members")}
                </span>
              </div>
            </div>
            <div class="flex gap-2 shrink-0">
              <button phx-click="manage_members" phx-value-id={group.id} class="btn btn-ghost btn-sm">
                <.icon name="hero-users" class="size-4" /> {gettext("Members")}
              </button>
              <button
                phx-click="delete_group"
                phx-value-id={group.id}
                data-confirm={gettext("Delete this group? Its shares are removed too.")}
                class="btn btn-ghost btn-sm text-error"
              >
                <.icon name="hero-trash" class="size-4" />
              </button>
            </div>
          </div>

          <p :if={@groups == []} class="text-sm text-base-content/50 text-center py-8">
            {gettext("No groups yet — create one to share with several people at once.")}
          </p>
        </div>

        <%!-- Members panel — mismo molde que el bloque "Add users" del panel de
               miembros del workspace: lista de miembros con avatar y ✕, y abajo
               las DOS puertas para agregar (correo conocido + buscador sobre la
               lista de usuarios). --%>
        <div :if={@members_group} id="group-members-panel" class="surface-2 rounded-2xl p-5 space-y-4">
          <div class="flex items-center justify-between">
            <h2 class="text-heading">
              {gettext("Members of")} <span class="text-primary">{@members_group.name}</span>
            </h2>
            <button phx-click="manage_members" phx-value-id="0" class="btn btn-ghost btn-sm">
              {gettext("Close")}
            </button>
          </div>

          <%!-- Current members --%>
          <div>
            <h3 class="text-caption font-semibold text-base-content/60 uppercase tracking-wider mb-1">
              {gettext("Members")} ({length(@members)})
            </h3>

            <p :if={@members == []} class="text-sm text-base-content/50 text-center py-4">
              {gettext("No members yet.")}
            </p>

            <div :if={@members != []} class="space-y-2">
              <div
                :for={member <- @members}
                id={"group-member-#{member.id}"}
                class="flex items-center justify-between gap-3 rounded-xl border border-base-content/10 px-3 py-2.5"
              >
                <div class="min-w-0 flex items-center gap-3">
                  <div class="size-8 rounded-full bg-base-content/10 flex items-center justify-center text-xs font-semibold">
                    {String.slice(member.name || member.email || "?", 0, 1)}
                  </div>
                  <div class="min-w-0">
                    <p class="text-sm font-medium truncate">{member.email}</p>
                    <p :if={member.name} class="text-xs text-base-content/60 truncate">
                      {member.name}
                    </p>
                  </div>
                </div>

                <button
                  type="button"
                  phx-click="remove_member"
                  phx-value-group_id={@members_group.id}
                  phx-value-user_id={member.id}
                  data-confirm={gettext("Remove %{user} from this group?", user: member.email)}
                  class="btn btn-ghost btn-xs btn-circle text-error"
                  title={gettext("Remove from group")}
                >
                  <.icon name="hero-x-mark" class="size-4" />
                </button>
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
                "Add an existing account to this group. People must already have a Dran account — there is no invitation email, membership is granted as soon as you add them."
              )}
            </p>

            <%!-- Add by email (works for anyone, no need to search first) --%>
            <.form
              for={@invite_form}
              id="group-invite-form"
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
              <button
                type="submit"
                class="btn btn-primary btn-sm mb-2 transition-colors active:scale-95"
                phx-disable-with={gettext("Adding…")}
              >
                <.icon name="hero-plus" class="size-4" />
                {gettext("Add")}
              </button>
            </.form>

            <form id="group-user-search-form" phx-change="search_members" class="relative">
              <.icon
                name="hero-magnifying-glass"
                class="absolute left-3 top-2.5 size-4 text-base-content/50"
              />
              <input
                type="text"
                name="q"
                value={@member_search}
                placeholder={gettext("Search users by email or name...")}
                class="w-full pl-9 pr-3 py-2 text-sm rounded-lg border border-base-300 bg-base-100 transition-colors duration-150 focus:outline-none focus:ring-1 focus:ring-primary"
              />
            </form>

            <div class="mt-3 space-y-2">
              <% member_ids = MapSet.new(@members, & &1.id)
              q = String.downcase(@member_search || "")

              candidates =
                Enum.reject(@all_users, &MapSet.member?(member_ids, &1.id))

              filtered =
                candidates
                |> Enum.filter(fn user ->
                  q == "" or
                    String.contains?(String.downcase(user.email || ""), q) or
                    (user.name && String.contains?(String.downcase(user.name), q))
                end)
                |> Enum.take(5) %>

              <div
                :if={filtered == [] and @member_search != ""}
                class="text-sm text-base-content/50 py-3 text-center"
              >
                {gettext("No users match your search.")}
              </div>

              <p
                :if={candidates == []}
                class="text-sm text-base-content/50 text-center py-3"
              >
                {gettext("Everyone on this instance is already in this group.")}
              </p>

              <div
                :for={user <- filtered}
                id={"group-candidate-#{user.id}"}
                class="flex items-center justify-between gap-3 rounded-xl border border-base-content/10 px-3 py-2.5"
              >
                <div class="min-w-0 flex items-center gap-3">
                  <div class="size-8 rounded-full bg-base-content/10 flex items-center justify-center text-xs font-semibold">
                    {String.slice(user.name || user.email || "?", 0, 1)}
                  </div>
                  <div class="min-w-0">
                    <p class="text-sm font-medium truncate">{user.email}</p>
                    <p :if={user.name} class="text-xs text-base-content/60 truncate">
                      {user.name}
                    </p>
                  </div>
                </div>

                <button
                  type="button"
                  id={"group-add-#{user.id}"}
                  phx-click="add_member"
                  phx-value-group_id={@members_group.id}
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

        <%!-- Copia del slug: lee el valor del `data-slug` del `<code>` apuntado
               por `data-copy-target`, con fallback de clipboard. Mismo molde
               que `.CopyAccountApiToken` del panel de la cuenta. --%>
        <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyGroupSlug">
          export default {
            mounted() {
              this.el.addEventListener("click", () => {
                const target = document.getElementById(this.el.dataset.copyTarget);
                if (!target) return;
                const text = target.dataset.slug;
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
      </div>
    </Layouts.app>
    """
  end
end
