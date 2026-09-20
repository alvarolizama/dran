defmodule DranWeb.Components.ShareDialog do
  @moduledoc """
  The share dialog (W4, contract-instance-visibility-20260919).

  Manages `content_shares` grants on one content row: pick users and groups,
  list the existing grants, revoke them. Visibility itself (private |
  public | shared) lives in the item's form — the dialog only appears once
  the owner set `shared`.

  Shares grant READ access only (contract ?03).
  """

  use DranWeb, :html


  attr :id, :string, default: "share-dialog"
  attr :open, :boolean, default: false
  attr :resource_type, :string, required: true
  attr :resource_id, :string, required: true
  attr :shares, :list, default: []
  attr :users, :list, default: []
  attr :groups, :list, default: []

  def share_dialog(assigns) do
    ~H"""
    <div
      :if={@open}
      id={@id}
      class="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/40"
      phx-click-away="close_share"
      phx-window-keydown="close_share"
      phx-key="escape"
    >
      <div class="surface-2 w-full max-w-md rounded-2xl shadow-xl max-h-[85vh] flex flex-col" phx-click="noop">
        <header class="flex items-center justify-between px-5 py-4 border-b border-base-content/10">
          <div>
            <h2 class="text-heading">{gettext("Share")}</h2>
            <p class="text-caption mt-0.5">
              {gettext("Read access only — editing stays with the owner.")}
            </p>
          </div>
          <button phx-click="close_share" class="btn btn-ghost btn-sm btn-square" aria-label={gettext("Close")}>
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </header>

        <div class="px-5 py-4 space-y-4 overflow-y-auto">
          <%!-- Share with a user --%>
          <form id="share-user-form" phx-submit="share_with_user" class="flex gap-2">
            <select
              name="user_id"
              class="select select-sm flex-1 rounded-lg border-base-300 bg-base-100"
              aria-label={gettext("User")}
            >
              <option value="">{gettext("Share with a user…")}</option>
              <option :for={u <- @users} value={u.id}>{u.email}</option>
            </select>
            <button type="submit" class="btn btn-primary btn-sm">
              <.icon name="hero-plus" class="size-4" /> {gettext("Add")}
            </button>
          </form>

          <%!-- Share with a group --%>
          <form id="share-group-form" phx-submit="share_with_group" class="flex gap-2">
            <select
              name="group_id"
              class="select select-sm flex-1 rounded-lg border-base-300 bg-base-100"
              aria-label={gettext("Group")}
            >
              <option value="">{gettext("Share with a group…")}</option>
              <option :for={g <- @groups} value={g.id}>{g.name}</option>
            </select>
            <button type="submit" class="btn btn-primary btn-sm">
              <.icon name="hero-plus" class="size-4" /> {gettext("Add")}
            </button>
          </form>

          <%!-- Current grants --%>
          <div :if={@shares != []} class="space-y-1.5">
            <h3 class="text-caption font-semibold text-base-content/60 uppercase tracking-wider">
              {gettext("Shared with")}
            </h3>
            <div
              :for={share <- @shares}
              class="flex items-center justify-between gap-2 px-3 py-2 rounded-lg bg-base-200/40"
              id={"share-row-#{share.id}"}
            >
              <span class="flex items-center gap-2 min-w-0 text-sm">
                <.icon
                  name={if share.user_group_id, do: "hero-user-group", else: "hero-user"}
                  class="size-4 text-base-content/50 shrink-0"
                />
                <span class="truncate">{share_target_label(share, @users, @groups)}</span>
              </span>
              <button
                phx-click="unshare"
                phx-value-id={share.id}
                class="btn btn-ghost btn-xs text-error shrink-0"
                title={gettext("Revoke this grant")}
              >
                <.icon name="hero-x-mark" class="size-3.5" />
              </button>
            </div>
          </div>

          <p :if={@shares == []} class="text-sm text-base-content/50 text-center py-4">
            {gettext("Not shared with anyone yet.")}
          </p>
        </div>
      </div>
    </div>
    """
  end

  defp share_target_label(%{user_id: user_id, user_group_id: nil}, users, _groups)
       when not is_nil(user_id) do
    case Enum.find(users, &(&1.id == user_id)) do
      %{email: email} -> email
      nil -> "user ##{user_id}"
    end
  end

  defp share_target_label(%{user_group_id: group_id}, _users, groups)
       when not is_nil(group_id) do
    case Enum.find(groups, &(&1.id == group_id)) do
      %{name: name} -> name
      nil -> "group ##{group_id}"
    end
  end
end
