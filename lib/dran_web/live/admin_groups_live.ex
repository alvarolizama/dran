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
     |> assign(:members, Sharing.list_group_members(group.id))
     |> assign(:all_users, Accounts.list_users())}
  end

  def handle_event("add_member", %{"group_id" => group_id, "user_id" => user_id}, socket)
      when user_id != "" do
    group = Sharing.get_group!(String.to_integer(group_id))
    {:ok, _} = Sharing.add_group_member(group, String.to_integer(user_id))

    case handle_event("manage_members", %{"id" => group_id}, socket) do
      {:noreply, updated} -> {:noreply, updated}
    end
  end

  def handle_event("add_member", _params, socket), do: {:noreply, socket}

  def handle_event("remove_member", %{"group_id" => group_id, "user_id" => user_id}, socket) do
    group = Sharing.get_group!(String.to_integer(group_id))
    :ok = Sharing.remove_group_member(group, String.to_integer(user_id))

    case handle_event("manage_members", %{"id" => group_id}, socket) do
      {:noreply, updated} -> {:noreply, updated}
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
            <div class="min-w-0">
              <p class="font-medium truncate">{group.name}</p>
              <p class="text-caption text-base-content/50">
                {group.members} {gettext("members")} · /{group.slug}
              </p>
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

        <%!-- Members panel --%>
        <div :if={@members_group} id="group-members-panel" class="surface-2 rounded-2xl p-5 space-y-4">
          <div class="flex items-center justify-between">
            <h2 class="text-heading">
              {gettext("Members of")} <span class="text-primary">{@members_group.name}</span>
            </h2>
            <button phx-click="manage_members" phx-value-id="0" class="btn btn-ghost btn-sm">
              {gettext("Close")}
            </button>
          </div>

          <form id="group-add-member-form" phx-submit="add_member" class="flex gap-2">
            <input type="hidden" name="group_id" value={@members_group.id} />
            <select
              name="user_id"
              class="select select-sm flex-1 rounded-lg border-base-300 bg-base-100"
            >
              <option value="">{gettext("Add a user…")}</option>
              <option :for={u <- @all_users} value={u.id}>{u.email}</option>
            </select>
            <button type="submit" class="btn btn-primary btn-sm">
              <.icon name="hero-plus" class="size-4" /> {gettext("Add")}
            </button>
          </form>

          <div class="space-y-1.5">
            <div
              :for={member <- @members}
              id={"group-member-#{member.id}"}
              class="flex items-center justify-between px-3 py-2 rounded-lg bg-base-200/40"
            >
              <span class="text-sm truncate">{member.email}</span>
              <button
                phx-click="remove_member"
                phx-value-group_id={@members_group.id}
                phx-value-user_id={member.id}
                class="btn btn-ghost btn-xs text-error"
              >
                <.icon name="hero-x-mark" class="size-3.5" />
              </button>
            </div>
            <p :if={@members == []} class="text-sm text-base-content/50 text-center py-3">
              {gettext("No members yet.")}
            </p>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
