defmodule DranWeb.VersionCompare do
  @moduledoc """
  Shared LiveView handlers for version comparison events.

  Each page-type LiveView delegates `compare_version` and `clear_compare`
  events here. The LiveView must have `:page` in socket.assigns.
  """

  import Phoenix.Component, only: [assign: 2]

  def handle_event("compare_version", %{"version" => version_str}, socket) do
    page = socket.assigns.page
    version = String.to_integer(version_str)

    old_version = Dran.Brain.get_page_version(page.id, version)

    {:noreply, assign(socket, compare_version: old_version)}
  end

  def handle_event("clear_compare", _params, socket) do
    {:noreply, assign(socket, compare_version: nil)}
  end
end
