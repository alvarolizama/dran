defmodule DranWeb.PageController do
  use DranWeb, :controller

  @doc """
  The home route redirects to the notes index, which acts as the
  default landing page for the second-brain app.
  """
  def home(conn, _params) do
    redirect(conn, to: ~p"/panel/notes")
  end
end
