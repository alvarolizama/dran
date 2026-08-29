defmodule DranWeb.KanbanRedirectController do
  @moduledoc """
  Redirects the legacy read-only kanban URL to the interactive task board.
  """

  use DranWeb, :controller

  def redirect_to_tasks(conn, %{"workspace_slug" => workspace_slug}) do
    redirect(conn, to: ~p"/#{workspace_slug}/tasks")
  end
end
