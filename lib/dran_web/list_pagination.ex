defmodule DranWeb.ListPagination do
  @moduledoc """
  Shared pagination state + handlers for page list views.

  Every page-type LiveView (note, concept, project, goal, plan, etc.) feeds
  `DranWeb.PageListComponents.page_list/1`, which renders the visible pages
  and the archived section. Pagination is client-side: the LiveView holds the
  full lists in memory and the component shows a window of them, revealing
  `@page_size` more each time the user clicks "Load more".
  """

  @page_size 30

  import Phoenix.Component, only: [assign: 2]

  @doc "Default pagination assigns. Merge into the list view's assigns."
  def default_assigns do
    %{
      visible_count: @page_size,
      show_archived: false,
      archived_visible_count: @page_size
    }
  end

  @doc "Whether the non-archived list has more rows than currently visible."
  def has_more?(pages, visible_count), do: length(pages) > visible_count

  @doc "Whether the archived list has more rows than currently visible."
  def has_more_archived?(archived, archived_visible_count),
    do: length(archived) > archived_visible_count

  @doc "Reveal the next batch of non-archived pages."
  def handle_load_more(socket) do
    assign(socket, visible_count: socket.assigns.visible_count + @page_size)
  end

  @doc "Toggle between the active and archived views."
  def handle_toggle_archived(socket) do
    assign(socket, show_archived: not socket.assigns.show_archived)
  end

  @doc "Reveal the next batch of archived pages."
  def handle_load_more_archived(socket) do
    assign(socket, archived_visible_count: socket.assigns.archived_visible_count + @page_size)
  end
end
