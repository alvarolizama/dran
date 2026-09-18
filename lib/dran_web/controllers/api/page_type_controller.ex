defmodule DranWeb.API.PageTypeController do
  @moduledoc """
  GET /api/workspaces/:slug/page-types — the workspace's effective page types.

  Read-only introspection so any identity with read access to the workspace
  can discover its vocabulary — the four built-in types (`note`, `entity`,
  `concept`, `reference`) plus the workspace's own custom types — instead of
  hardcoding the built-ins. Same shape as the `page_types` / `page_type_defs`
  fields of `GET /api/agent/config`, but reachable by any token (agent/config
  is agent-key-only).
  """

  use DranWeb, :controller

  alias Dran.Knowledge

  def index(conn, %{"slug" => slug}) do
    with_context(conn, slug, fn conn, context ->
      json(conn, %{
        data: %{
          page_types: Knowledge.effective_page_types(context),
          page_type_defs: Knowledge.page_type_defs(context)
        }
      })
    end)
  end
end
