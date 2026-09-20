defmodule DranWeb.API.PageTypeController do
  @moduledoc """
  GET /api/workspaces/:slug/page-types — the INSTANCE's effective page types.

  W5 (single-workspace): the `:slug` segment is legacy — the answer is always
  the instance workspace's types. Read-only introspection so any identity can
  discover the vocabulary (the four built-ins plus custom types). Same shape
  as `GET /api/agent/config`'s `page_types` / `page_type_defs`, but reachable
  by any token.
  """

  use DranWeb, :controller

  alias Dran.Knowledge

  def index(conn, params) do
    with_context(conn, params["slug"], fn conn, context ->
      json(conn, %{
        data: %{
          page_types: Knowledge.effective_page_types(context),
          page_type_defs: Knowledge.page_type_defs(context)
        }
      })
    end)
  end
end
