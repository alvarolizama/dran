defmodule DranWeb.AdminSystemLive do
  @moduledoc "System info — F3"
  use DranWeb, :live_view

  alias DranWeb.Plugs.Auth

  @impl true
  def mount(_params, session, socket) do
    {socket, _context} = Auth.assign_to_socket(socket, session)

    socket = assign(socket, active_nav: "admin", page_title: gettext("Sistema"))
    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_user={@current_user} active_nav="admin">
      <div class="flex-1 overflow-y-auto">
        <div class="w-full p-6 space-y-8">
          <h1 class="text-title">{gettext("Sistema")}</h1>
          <p class="text-caption">{gettext("System info — F3")}</p>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
