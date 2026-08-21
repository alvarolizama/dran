defmodule DranWeb.WorkspaceSettingsLive do
  @moduledoc """
  Workspace configuration page: page types, enabled features, and brain
  tuning for a single workspace.

  Access is enforced by the `:workspace_admin` router pipeline (owner/admin of
  the workspace ∪ instance owner) plus an `attach_hook` defense-in-depth that
  halts every event for non-owners/admins. This is the F4 stub — the full
  implementation (page types + features + brain tuning forms) lands in phase
  F4.
  """

  use DranWeb, :live_view

  alias DranWeb.Plugs.Auth

  @impl true
  def mount(_params, session, socket) do
    {socket, _context} = Auth.assign_to_socket(socket, session)

    socket =
      socket
      |> assign(active_nav: "settings", page_title: gettext("Workspace settings"))

    {:ok, socket}
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
      active_nav="settings"
    >
      <div class="flex-1 overflow-y-auto">
        <div class="w-full p-6 space-y-8">
          <div class="space-y-1">
            <h1 class="text-title">{gettext("Workspace settings")}</h1>
            <p class="text-caption">
              {if @workspace, do: @workspace.name, else: gettext("No workspace")}
            </p>
          </div>
          <p class="text-sm text-base-content/60">
            {gettext("Workspace configuration lands in phase F4.")}
          </p>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
