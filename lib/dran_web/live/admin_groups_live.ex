defmodule DranWeb.AdminGroupsLive do
  @moduledoc """
  Group administration (W4, contract-instance-visibility-20260919).

  Instance admins create/rename/delete `user_groups` and manage their
  memberships — the share-with-group targets. Reachable at /admin/groups
  under the :admin pipeline (instance owner ∪ admin role).

  ## La superficie está en el molde de la casa

  El header es el compartido (`resource_list_header/1`), el alta y el
  renombrado son el MISMO modal abierto por estado de URL (`?new=true` y
  `?edit=<id>`, cerrado con `push_patch`) y el vacío de la colección es
  `resource_empty_state/1` por CONTADOR. El renombrado, que antes era una
  puerta sin UI, se administra desde la fila.

  El panel de miembros queda EN la página (no es un modal): es el port del
  bloque «Add users» del panel de miembros del workspace.
  """

  use DranWeb, :live_view

  alias Dran.Accounts
  alias Dran.Accounts.UserGroup
  alias Dran.Sharing

  @index_path "/admin/groups"

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
      |> assign(:group_modal, nil)
      |> assign(:editing_group, nil)
      |> assign(:group_submit_event, "save_group")
      |> assign_group_form(nil)
      |> assign_groups()
      |> assign(:members_group, nil)
      |> assign(:members, [])
      |> assign(:all_users, [])
      |> assign(:member_search, "")
      |> assign(:invite_form, blank_invite_form())

    {:ok, socket}
  end

  # El alta y el renombrado son ESTADO DE URL (C11): `?new=true` abre el modal
  # de creación y `?edit=<id>` el de renombrado. Este es el ÚNICO lugar que los
  # administra, así que recargar o entrar por un enlace deja el modal correcto
  # abierto; la ✕ vuelve a la URL limpia con `push_patch` — nunca
  # `push_navigate`, que remonta el LiveView y pierde el estado.
  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      case params do
        %{"new" => "true"} ->
          open_group_modal(socket, nil)

        %{"edit" => id} ->
          case find_group(id) do
            nil -> close_group_modal(socket)
            group -> open_group_modal(socket, group)
          end

        _ ->
          close_group_modal(socket)
      end

    {:noreply, socket}
  end

  defp open_group_modal(socket, group) do
    socket
    |> assign(:editing_group, group)
    |> assign(:group_modal, if(group, do: :rename, else: :new))
    |> assign(:group_submit_event, if(group, do: "rename_group", else: "save_group"))
    |> assign_group_form(group)
  end

  defp close_group_modal(socket) do
    socket
    |> assign(:group_modal, nil)
    |> assign(:editing_group, nil)
    |> assign(:group_submit_event, "save_group")
  end

  defp assign_group_form(socket, %UserGroup{} = group) do
    assign(socket, :group_form, to_form(%{"name" => group.name}, as: :group))
  end

  defp assign_group_form(socket, _group), do: assign(socket, :group_form, new_group_form())

  defp assign_groups(socket) do
    groups =
      Enum.map(Sharing.list_groups_with_counts(), fn {group, count} ->
        %{id: group.id, name: group.name, slug: group.slug, members: count}
      end)

    socket
    |> assign(:groups, groups)
    # El contador viaja aparte: el vacío se decide por CONTADOR, no por la lista.
    |> assign(:group_count, length(groups))
  end

  @impl true
  def handle_event("save_group", %{"group" => %{"name" => name}}, socket) do
    case Sharing.create_group(%{name: name}) do
      {:ok, _group} ->
        {:noreply,
         socket
         |> assign_groups()
         |> close_group_modal()
         |> push_patch(to: @index_path)
         |> put_flash(:info, gettext("Group created."))}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:group_form, to_form(changeset, as: :group))
         |> put_flash(:error, gettext("Could not create the group."))}
    end
  end

  # Payload incompleto o forjado: no hay nombre que crear. Sin esta cláusula el
  # evento tira el proceso en vez de no hacer nada.
  def handle_event("save_group", _params, socket), do: {:noreply, socket}

  # El renombrado es la MISMA puerta de dominio que ya existía (`update_group/2`),
  # ahora con UI: `?edit=<id>` abre el modal y el submit llega con el id del
  # grupo en el propio form. Un id desconocido no hace nada.
  def handle_event("rename_group", %{"_id" => id, "group" => %{"name" => name}}, socket) do
    case find_group(id) do
      nil ->
        {:noreply, close_group_modal(socket) |> push_patch(to: @index_path)}

      group ->
        case Sharing.update_group(group, %{name: name}) do
          {:ok, _updated} ->
            {:noreply,
             socket
             |> assign_groups()
             |> close_group_modal()
             |> push_patch(to: @index_path)
             |> put_flash(:info, gettext("Group renamed."))}

          {:error, changeset} ->
            {:noreply,
             socket
             |> assign(:group_form, to_form(changeset, as: :group))
             |> put_flash(:error, gettext("Could not rename the group."))}
        end
    end
  end

  def handle_event("rename_group", _params, socket), do: {:noreply, socket}

  def handle_event("close_group_modal", _params, socket) do
    {:noreply, socket |> close_group_modal() |> push_patch(to: @index_path)}
  end

  def handle_event("delete_group", %{"id" => id}, socket) do
    case find_group(id) do
      nil ->
        {:noreply, socket}

      group ->
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
  end

  def handle_event("delete_group", _params, socket), do: {:noreply, socket}

  # Membership is managed inline per group row. id "0" closes the panel.
  def handle_event("manage_members", %{"id" => "0"}, socket) do
    {:noreply, assign(socket, :members_group, nil)}
  end

  def handle_event("manage_members", %{"id" => id}, socket) do
    case find_group(id) do
      nil ->
        {:noreply, socket}

      group ->
        {:noreply,
         socket
         |> assign(:members_group, group)
         # Abrir (o cambiar de) grupo arranca con la búsqueda limpia: el filtro
         # pertenece al panel donde se escribió.
         |> assign(:member_search, "")
         |> assign(:invite_form, blank_invite_form())
         |> assign_members(group.id)}
    end
  end

  def handle_event("manage_members", _params, socket), do: {:noreply, socket}

  # Filtro en vivo sobre la lista local de usuarios — una query por tecla no
  # hace falta. Es el mismo molde del panel de miembros del workspace
  # (`workspace_settings_live.ex`, bloque "Add users").
  def handle_event("search_members", %{"q" => q}, socket) do
    {:noreply, assign(socket, :member_search, q)}
  end

  def handle_event("add_member", %{"group_id" => group_id, "user_id" => user_id}, socket) do
    member_event(socket, group_id, user_id, fn group, uid ->
      _ = Sharing.add_group_member(group, uid)
    end)
  end

  # Payload incompleto o forjado: no hay a quién agregar. El select viejo tenía
  # su propia cláusula para el envío con el `user_id` vacío; sin ésta, un evento
  # sin `user_id` tira el proceso en vez de no hacer nada.
  def handle_event("add_member", _params, socket), do: {:noreply, socket}

  def handle_event("remove_member", %{"group_id" => group_id, "user_id" => user_id}, socket) do
    member_event(socket, group_id, user_id, fn group, uid ->
      :ok = Sharing.remove_group_member(group, uid)
    end)
  end

  def handle_event("remove_member", _params, socket), do: {:noreply, socket}

  # El grupo cerrado no tiene formulario que dispare esto; la cláusula existe
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

  def handle_event("invite_member", _params, socket), do: {:noreply, socket}

  # Una sola puerta para las dos membresías: el grupo se resuelve por id contra
  # la lista (un id forjado no existe, no revienta) y el user id se castea — el
  # evento es input no verificado.
  defp member_event(socket, group_id, user_id, fun) do
    with %UserGroup{} = group <- find_group(group_id),
         uid when is_integer(uid) <- int_or_nil(user_id) do
      fun.(group, uid)

      {:noreply,
       socket
       |> assign_members(group.id)
       |> put_flash(:info, gettext("Membership updated"))}
    else
      _ -> {:noreply, socket}
    end
  end

  defp assign_members(socket, group_id) do
    socket
    |> assign(:members, Sharing.list_group_members(group_id))
    |> assign(:all_users, Accounts.list_users())
  end

  defp blank_invite_form, do: to_form(%{"email" => ""}, as: :invite)

  defp new_group_form, do: to_form(%{"name" => ""}, as: :group)

  # El grupo por id, SIN `get_group!/1`: los ids llegan del cliente (un `?edit=`
  # a mano, un `phx-value-` forjado) y una fila inexistente tiene que devolver
  # `nil` — que la lectura reviente mataría el proceso del LiveView.
  defp find_group(id) do
    case int_or_nil(id) do
      nil -> nil
      int -> Enum.find(Sharing.list_groups(), &(&1.id == int))
    end
  end

  defp int_or_nil(value) when is_integer(value), do: value

  defp int_or_nil(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp int_or_nil(_value), do: nil

  @impl true
  def render(assigns) do
    # El modal sólo existe cuando `handle_params` pasó por una rama que lo
    # administra: se normalizan los assigns para que cualquier render lo tenga.
    assigns =
      assigns
      |> assign(:group_modal, Map.get(assigns, :group_modal, nil))
      |> assign(:editing_group, Map.get(assigns, :editing_group, nil))
      |> assign(:group_submit_event, Map.get(assigns, :group_submit_event, "save_group"))
      |> assign(:group_count, Map.get(assigns, :group_count, 0))
      |> assign(:members_group, Map.get(assigns, :members_group, nil))

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
        <.resource_list_header
          title={gettext("Groups")}
          new_path={~p"/admin/groups?new=true"}
          new_id="group-new"
          new_testid="new-group-button"
          new_label={gettext("New group")}
        />

        <p class="text-caption -mt-4">
          {gettext(
            "Share content with several people at once — a group is a list of users used as a share target."
          )}
        </p>

        <div class="space-y-2">
          <div
            :for={group <- @groups}
            id={"group-row-#{group.id}"}
            data-testid="group-row"
            class="surface-2 lift hover:border-primary/40 p-4 rounded-xl"
          >
            <div class="flex items-center gap-3">
              <span class="size-8 rounded-md bg-primary/10 flex items-center justify-center">
                <.icon name="hero-user-group" class="size-4 text-primary" />
              </span>
              <p class="font-medium leading-snug flex-1 truncate">{group.name}</p>
              <span class="text-[11px] font-medium px-2 py-0.5 rounded-full bg-base-300 text-base-content/60">
                {group.members} {gettext("members")}
              </span>
            </div>

            <div class="flex flex-wrap items-center justify-between gap-2 mt-3">
              <div class="flex items-center gap-2 min-w-0">
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
              </div>

              <div class="flex items-center gap-2 shrink-0">
                <button
                  type="button"
                  id={"group-members-#{group.id}"}
                  phx-click="manage_members"
                  phx-value-id={group.id}
                  class="btn btn-ghost btn-sm"
                >
                  <.icon name="hero-users" class="size-4" /> {gettext("Members")}
                </button>
                <%!-- Renombrar entra por la MISMA puerta que el alta (`?edit=<id>`
                       abre el modal con el nombre puesto): antes el handler
                       existía sin ningún control que lo alcanzara. --%>
                <.link
                  patch={~p"/admin/groups?edit=#{group.id}"}
                  id={"group-edit-#{group.id}"}
                  class="btn btn-ghost btn-sm"
                  title={gettext("Rename this group")}
                >
                  <.icon name="hero-pencil" class="size-4" /> {gettext("Edit")}
                </.link>
                <button
                  type="button"
                  id={"group-delete-#{group.id}"}
                  phx-click="delete_group"
                  phx-value-id={group.id}
                  data-confirm={gettext("Delete this group? Its shares are removed too.")}
                  class="btn btn-ghost btn-sm text-error"
                >
                  <.icon name="hero-trash" class="size-4" />
                </button>
              </div>
            </div>
          </div>

          <.resource_empty_state
            :if={@group_count == 0}
            icon="hero-user-group"
            title={gettext("No groups yet")}
            description={
              gettext("A group is a list of users you can share content with in one step.")
            }
            cta={gettext("Create group")}
            new_path={~p"/admin/groups?new=true"}
          />
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

        <%!-- Alta y renombrado: el MISMO modal del molde, abierto por estado de
               URL (`?new=true` / `?edit=<id>`) y con el botón Guardar en el
               footer del shell apuntando al form del cuerpo por su id. --%>
        <.resource_modal
          :if={@group_modal}
          id="group-resource-modal"
          title={if @editing_group, do: gettext("Rename group"), else: gettext("New group")}
          pill="GROUP"
          on_close="close_group_modal"
          form_id="group-form"
          submit_label={if @editing_group, do: gettext("Save"), else: gettext("Create")}
          cancel_label={gettext("Cancel")}
          max_w="max-w-xl"
        >
          <div class="max-w-xl">
            <.form
              for={@group_form}
              id="group-form"
              phx-submit={@group_submit_event}
              class="space-y-4"
            >
              <input
                :if={@editing_group}
                type="hidden"
                name="_id"
                value={@editing_group.id}
              />
              <.input
                field={@group_form[:name]}
                type="text"
                label={gettext("Name")}
                placeholder={gettext("e.g. Design team")}
                autofocus
              />
            </.form>
          </div>
        </.resource_modal>

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
