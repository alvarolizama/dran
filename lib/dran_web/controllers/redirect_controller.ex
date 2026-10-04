defmodule DranWeb.RedirectController do
  @moduledoc """
  Legacy `/…:workspace_slug/…` URLs → 301 to the flat single-instance routes
  (W1, contract-instance-visibility-20260919, D2).

  Bookmarks, browser history and plugin-built links built against the old
  multi-workspace router keep working: the slug segment is dropped and the
  rest of the path is preserved.
  """
  use DranWeb, :controller

  def graph_json(conn, %{"workspace_slug" => _slug}) do
    redirect(conn, to: "/graph/json")
  end

  # /:workspace_slug/:type/:slug and every other nested path: drop the slug
  # segment, keep the rest.
  def rest(conn, %{"workspace_slug" => _slug, "rest" => rest}) do
    path = "/" <> Enum.join(List.wrap(rest), "/")
    redirect(conn, to: path)
  end

  # `/settings/instance` → `/admin/instance`: configuring the instance is
  # instance policy and lives in the admin shell (`pipeline :admin`,
  # owner-only). The hop is here — and not as a live route — so the old URL
  # keeps answering for bookmarks without mounting a page for a user the
  # destination would refuse.
  def instance_settings(conn, _params) do
    redirect(conn, to: "/admin/instance")
  end
end
